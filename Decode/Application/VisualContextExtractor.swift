import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Protocol for visual context extraction — for testability.
protocol VisualContextExtracting: Sendable {
    func extract(from image: CGImage) async -> VisualContext?
}

/// Extracts compact contextual evidence from a screenshot using a vision LLM.
///
/// Stateless service shared by Selection and Screenshot Mode coordinators.
/// Takes a `CGImage`, converts to JPEG, sends to a vision-capable AI provider,
/// and parses the response into structured `[VisualEvidence]` items.
///
/// Returns `nil` on any failure — the coordinator treats `nil` as
/// "proceed without visual context" (graceful degradation).
struct VisualContextExtractor: VisualContextExtracting, Sendable {

    /// The AI provider used for vision completion.
    private let provider: any AIProviderProtocol

    /// Configuration for cropping the captured screenshot before vision processing.
    private let captureConfiguration: VisualContextCaptureConfiguration

    /// The extraction prompt version, tracked for analytics.
    static let promptVersion = "v1"

    init(
        provider: any AIProviderProtocol,
        captureConfiguration: VisualContextCaptureConfiguration = .default
    ) {
        self.provider = provider
        self.captureConfiguration = captureConfiguration
    }

    // MARK: - Extraction

    func extract(from image: CGImage) async -> VisualContext? {
        #if DEBUG
        let tPipelineStart = CFAbsoluteTimeGetCurrent()
        #endif

        // 1. Crop inner rectangle to discard window chrome and reduce tokens.
        let sourceImage = cropInnerRect(from: image)

        #if DEBUG
        let tCropDone = CFAbsoluteTimeGetCurrent()
        let originalPixels = image.width * image.height
        let croppedPixels = sourceImage.width * sourceImage.height
        let removedPercent = originalPixels > 0 ? Double(originalPixels - croppedPixels) / Double(originalPixels) * 100 : 0
        print("[LATENCY]   Edge crop:           \(String(format: "%.0f", (tCropDone - tPipelineStart) * 1000))ms")
        print("[LATENCY]     Original: \(image.width)×\(image.height)")
        print("[LATENCY]     Cropped:  \(sourceImage.width)×\(sourceImage.height)")
        print("[LATENCY]     Pixels removed: \(String(format: "%.0f", removedPercent))%")
        #endif

        // 2. Convert CGImage to JPEG data.
        guard let jpegData = jpegData(from: sourceImage) else {
            #if DEBUG
            print("[VisualContext] failed to convert CGImage to JPEG")
            #endif
            return nil
        }

        #if DEBUG
        let tJpegDone = CFAbsoluteTimeGetCurrent()
        print("[LATENCY]   JPEG conversion:     \(String(format: "%.0f", (tJpegDone - tCropDone) * 1000))ms (\(sourceImage.width)x\(sourceImage.height) → \(jpegData.count) bytes)")
        #endif

        // 2. Check image size limit.
        guard jpegData.count <= AILimits.maxVisionImageBytes else {
            #if DEBUG
            print("[VisualContext] image too large: \(jpegData.count) bytes (max \(AILimits.maxVisionImageBytes))")
            #endif
            return nil
        }

        // 3. Call vision LLM with timeout.
        #if DEBUG
        let tApiStart = CFAbsoluteTimeGetCurrent()
        #endif
        let rawOutput: String
        do {
            rawOutput = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await provider.generateVisionCompletion(
                        imageData: jpegData,
                        prompt: Self.extractionPrompt,
                        mode: "vision"
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(AILimits.visionTimeoutSeconds))
                    throw CancellationError()
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
        } catch {
            #if DEBUG
            let apiMs = (CFAbsoluteTimeGetCurrent() - tApiStart) * 1000
            let errorDetail: String
            if error is CancellationError {
                errorDetail = "TIMEOUT after \(String(format: "%.0f", apiMs))ms"
            } else {
                errorDetail = "\(error.localizedDescription) after \(String(format: "%.0f", apiMs))ms"
            }
            print("[VisualContext] gateway request FAILED: \(errorDetail)")
            await MainActor.run {
                EnhancedExplanationDebug.shared.lastError = errorDetail
                EnhancedExplanationDebug.shared.lastRawResponse = nil
                EnhancedExplanationDebug.shared.lastLatencyMs = apiMs
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
            }
            #endif
            return nil
        }

        #if DEBUG
        let tApiDone = CFAbsoluteTimeGetCurrent()
        let apiMs = (tApiDone - tApiStart) * 1000
        await MainActor.run {
            EnhancedExplanationDebug.shared.lastRawResponse = rawOutput
            EnhancedExplanationDebug.shared.lastLatencyMs = apiMs
        }
        #endif

        // 4. Lightweight validation — the vision model produces the final artifact.
        guard let validated = sanitize(rawOutput) else {
            #if DEBUG
            let totalMs = (CFAbsoluteTimeGetCurrent() - tPipelineStart) * 1000
            print("[LATENCY]   Vision API (total):  \(String(format: "%.0f", apiMs))ms")
            print("[LATENCY]   Sanitize:            <1ms (nil result)")
            print("[LATENCY]   Vision pipeline:     \(String(format: "%.0f", totalMs))ms")
            print("[VisualContext] sanitize returned nil — no additive context (\(rawOutput.count) chars)")
            await MainActor.run {
                EnhancedExplanationDebug.shared.lastError = "No additive context from \(rawOutput.count)-char response"
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
            }
            #endif
            return nil
        }

        #if DEBUG
        let tSanitizeDone = CFAbsoluteTimeGetCurrent()
        let totalMs = (tSanitizeDone - tPipelineStart) * 1000
        let lineCount = validated.components(separatedBy: "\n").count
        print("[LATENCY]   Vision API (total):  \(String(format: "%.0f", apiMs))ms (\(rawOutput.count) chars response)")
        print("[LATENCY]   Sanitize:            \(String(format: "%.1f", (tSanitizeDone - tApiDone) * 1000))ms → \(lineCount) lines, \(validated.count) chars")
        print("[LATENCY]   Vision pipeline:     \(String(format: "%.0f", totalMs))ms")
        #endif

        return VisualContext(content: validated)
    }

    // MARK: - JPEG Conversion

    /// Convert CGImage to JPEG data, resizing if wider than 1536px.
    private func jpegData(from image: CGImage) -> Data? {
        var sourceImage = image

        // Resize if wider than 1536px (per architecture spec).
        let maxWidth = 1536
        if sourceImage.width > maxWidth {
            let scale = Double(maxWidth) / Double(sourceImage.width)
            let newWidth = maxWidth
            let newHeight = Int(Double(sourceImage.height) * scale)

            guard let colorSpace = sourceImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: newWidth,
                      height: newHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return nil
            }
            context.interpolationQuality = .high
            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            guard let resized = context.makeImage() else { return nil }
            sourceImage = resized
        }

        // Encode as JPEG with 0.75 quality.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.75,
        ]
        CGImageDestinationAddImage(destination, sourceImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    // MARK: - Edge Cropping

    /// Crop the inner rectangle of a CGImage, removing a configurable percentage
    /// from each edge. Returns the original image if the crop would be invalid
    /// (e.g. too small, or configuration is zero).
    private func cropInnerRect(from image: CGImage) -> CGImage {
        let hPad = captureConfiguration.horizontalPaddingPercent
        let vPad = captureConfiguration.verticalPaddingPercent

        // No cropping needed.
        guard hPad > 0 || vPad > 0 else { return image }

        let w = Double(image.width)
        let h = Double(image.height)

        let cropX = (w * hPad).rounded()
        let cropY = (h * vPad).rounded()
        let cropW = (w - 2 * cropX).rounded()
        let cropH = (h - 2 * cropY).rounded()

        // Guard against degenerate crops.
        guard cropW >= 100, cropH >= 100 else { return image }

        let rect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }

    // MARK: - Lightweight Validation

    /// Sanitize raw vision output into a validated context string.
    ///
    /// The vision model produces the final artifact directly. This method
    /// performs only guardrail operations:
    /// - Strip `<think>…</think>` blocks (model reasoning leakage)
    /// - Trim whitespace and remove empty lines
    /// - Detect `NO_ADDITIONAL_CONTEXT` / `none` sentinel → return nil
    /// - Enforce character limit
    ///
    /// Returns `nil` when the output contains no additive context.
    func sanitize(_ rawOutput: String) -> String? {
        var text = rawOutput

        // Strip <think>…</think> blocks (Qwen reasoning leakage).
        while let startRange = text.range(of: "<think>", options: .caseInsensitive) {
            if let endRange = text.range(of: "</think>", options: .caseInsensitive, range: startRange.upperBound..<text.endIndex) {
                text.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            } else {
                // Unclosed <think> — remove everything from <think> onward.
                text.removeSubrange(startRange.lowerBound..<text.endIndex)
            }
        }

        // Remove empty lines and trim each line.
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Detect empty-output sentinel.
        let joined = lines.joined(separator: "\n")
        let normalized = joined.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty
            || normalized == "none"
            || normalized == "no_additional_context" {
            return nil
        }

        // Enforce character limit.
        if joined.count > AILimits.maxVisualEvidenceCharacters {
            // Keep complete lines that fit within the budget.
            var result: [String] = []
            var length = 0
            for line in lines {
                let addition = result.isEmpty ? line.count : line.count + 1 // +1 for \n
                if length + addition > AILimits.maxVisualEvidenceCharacters { break }
                result.append(line)
                length += addition
            }
            return result.isEmpty ? nil : result.joined(separator: "\n")
        }

        return joined
    }


    // MARK: - Extraction Prompt

    static let extractionPrompt = """
        Another AI will explain the highlighted code to a user. It can see ONLY the highlighted \
        text. You can see the entire screen.

        You are sending it one brief message before it writes the explanation. \
        Include only evidence that corrects what it will otherwise get wrong.

        Ask yourself: What will it misunderstand because it cannot see the rest of the screen?

        Provide that evidence as facts. Do not explain the code — the other AI reasons better \
        than you.

        WORTH REPORTING (changes the explanation):
        - Error or warning on or near the highlight — quote the text
        - Code outside the selection that alters its meaning — quote it
        - The selection is part of a larger construct whose role is not apparent from the \
        selection alone
        - Runtime state visible in debugger or console

        NOT WORTH REPORTING:
        - File names, line numbers, project structure
        - Anything already visible in the highlighted code
        - Editor appearance or UI elements
        - Anything you cannot clearly read on screen

        State the single most important observation. Add a second only if it independently \
        changes the explanation.

        If nothing would change the explanation, respond exactly: none
        """
}

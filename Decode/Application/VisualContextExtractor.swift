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

    /// The extraction prompt version, tracked for analytics.
    static let promptVersion = "v1"

    init(provider: any AIProviderProtocol) {
        self.provider = provider
    }

    // MARK: - Extraction

    func extract(from image: CGImage) async -> VisualContext? {
        // 1. Convert CGImage to JPEG data.
        guard let jpegData = jpegData(from: image) else {
            #if DEBUG
            print("[VisualContext] failed to convert CGImage to JPEG")
            #endif
            return nil
        }

        #if DEBUG
        print("[VisualContext] JPEG encoded: \(jpegData.count) bytes from \(image.width)x\(image.height) image")
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
        print("[VisualContext] gateway request starting (timeout=\(AILimits.visionTimeoutSeconds)s)...")
        let apiStartTime = CFAbsoluteTimeGetCurrent()
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
            let apiMs = (CFAbsoluteTimeGetCurrent() - apiStartTime) * 1000
            let errorDetail: String
            if error is CancellationError {
                errorDetail = "TIMEOUT after \(String(format: "%.0f", apiMs))ms"
            } else {
                errorDetail = "\(error.localizedDescription) after \(String(format: "%.0f", apiMs))ms"
            }
            print("[VisualContext] gateway request FAILED: \(errorDetail)")
            print("[VisualContext] error type: \(type(of: error)), description: \(error)")
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
        let apiMs = (CFAbsoluteTimeGetCurrent() - apiStartTime) * 1000
        print("[VisualContext] Railway response received in \(String(format: "%.0f", apiMs))ms")
        print("[VisualContext] raw response (\(rawOutput.count) chars):")
        print(rawOutput)
        await MainActor.run {
            EnhancedExplanationDebug.shared.lastRawResponse = rawOutput
            EnhancedExplanationDebug.shared.lastLatencyMs = apiMs
        }
        #endif

        // 4. Lightweight validation — the vision model produces the final artifact.
        guard let validated = sanitize(rawOutput) else {
            #if DEBUG
            print("[VisualContext] sanitize returned nil — no additive context")
            await MainActor.run {
                EnhancedExplanationDebug.shared.lastError = "No additive context from \(rawOutput.count)-char response"
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
            }
            #endif
            return nil
        }

        #if DEBUG
        let lineCount = validated.components(separatedBy: "\n").count
        print("[VisualContext] validated output: \(lineCount) lines, \(validated.count) chars")
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
        Another AI is explaining the highlighted code to a developer. \
        It already has the highlighted code's full text.

        Read the highlighted code. Use it as a query. \
        Search the rest of the screen for information that improves the explanation.

        EVERY LINE YOU OUTPUT must answer: \
        "What does the screen tell the explanation model that it cannot know from the highlighted code alone?"

        One excellent observation beats five mediocre ones. \
        Do not fill the output. Only include genuinely valuable evidence.

        HIGH VALUE (include if visible):
        compiler error or warning related to the selection
        nearby comment, TODO, FIXME explaining intent
        visible documentation about the selected code
        terminal output related to the selection
        nearby code that calls, is called by, or relates to the selection
        surrounding type or function signature NOT in the selection

        NEVER include:
        filename, language, editor, UI, layout, coordinates, image description, \
        markdown, XML, JSON, prose, explanation, reasoning, <think>, \
        or anything already in the highlighted code

        Output plain text. One observation per line. Max 5 lines. 50-100 tokens.

        Good output:
        nearby comment says TODO: migrate to async registration
        compiler warning: unused result of type 'Result<Int, Error>'
        function processQueue() calls this method in a retry loop

        If nothing qualifies, output exactly: none
        """
}

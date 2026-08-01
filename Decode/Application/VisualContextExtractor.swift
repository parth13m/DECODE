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

        // 4. Parse response into evidence items.
        let items = parseEvidence(rawOutput)
        #if DEBUG
        print("[VisualContext] parsed \(items.count) evidence items from raw response")
        for item in items {
            print("[VisualContext]   \(item.type): \(item.content)")
        }
        #endif

        guard !items.isEmpty else {
            #if DEBUG
            print("[VisualContext] WARNING: no evidence items parsed — raw response may be in unexpected format")
            await MainActor.run {
                EnhancedExplanationDebug.shared.lastError = "Parser produced 0 items from \(rawOutput.count)-char response"
                EnhancedExplanationDebug.shared.lastTimestamp = Date()
            }
            #endif
            return nil
        }

        // 5. Truncate if evidence exceeds character budget.
        let trimmedItems = trimToCharacterBudget(items)

        #if DEBUG
        if trimmedItems.count < items.count {
            print("[VisualContext] trimmed from \(items.count) to \(trimmedItems.count) items (character budget)")
        }
        #endif

        return VisualContext(items: trimmedItems)
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

    // MARK: - Response Parsing

    /// Parse the vision model's line-based "key: value" output into
    /// structured `VisualEvidence` items.
    func parseEvidence(_ rawOutput: String) -> [VisualEvidence] {
        rawOutput
            .split(separator: "\n")
            .compactMap { line -> VisualEvidence? in
                let str = line.trimmingCharacters(in: .whitespaces)
                guard let colonIndex = str.firstIndex(of: ":") else { return nil }
                let type = str[str.startIndex..<colonIndex]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let content = str[str.index(after: colonIndex)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !type.isEmpty, !content.isEmpty else { return nil }
                return VisualEvidence(type: type, content: content)
            }
    }

    /// Drop lowest-priority (last) items until formatted output is within
    /// the character budget.
    private func trimToCharacterBudget(_ items: [VisualEvidence]) -> [VisualEvidence] {
        var result = items
        while !result.isEmpty {
            let formatted = VisualContext(items: result).formatted()
            if formatted.count <= AILimits.maxVisualEvidenceCharacters {
                break
            }
            result.removeLast()
        }
        return result
    }

    // MARK: - Extraction Prompt

    static let extractionPrompt = """
        A separate AI model is explaining the highlighted code to a developer. \
        That model already has the full text of the highlighted code.

        Your job: find information OUTSIDE the highlighted code that the other model cannot know.

        QUALITY RULE: One excellent observation is better than five mediocre ones. \
        Only output evidence that changes or significantly improves the downstream explanation. \
        Never pad output. If only one observation is genuinely valuable, return only one line.

        DECISION RULE — for each observation ask:
        Can it be known from the highlighted code alone? → SKIP
        Will it materially improve the explanation? → if NO, SKIP

        OUTPUT exactly: key: value (one per line, max 5 lines)

        PRIORITY (highest first):
        1. error/warning: compiler or linter diagnostic related to the selection
        2. comment: nearby TODO, FIXME, or explanatory comment
        3. doc: visible documentation about the selected code
        4. terminal: related terminal/console output
        5. caller: function or method that calls into the selection
        6. signature: surrounding type or function signature NOT in the selection

        NEVER output: filename, language, editor, UI elements, layout, coordinates, \
        image description, markdown, prose, explanation, reasoning, tags, \
        or anything inside the highlighted code.

        Good output:
        comment: TODO migrate producer registration to async
        error: Cannot convert value of type 'Int' to 'String'
        terminal: build failed — missing return in closure

        If nothing qualifies, output exactly: none
        """
}

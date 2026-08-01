import Foundation

/// Central response-budget and input-guardrail policy for all AI providers.
///
/// Decode provides the API keys, so all inference costs are controlled here.
/// Every provider and coordinator must reference these constants instead of
/// inline literals.
enum AILimits {

    // MARK: - Response Budget

    /// Maximum tokens the model may generate for explanation and chat responses.
    static let maxResponseTokens = 4096

    /// Maximum tokens for lightweight connection validation requests.
    static let validationMaxTokens = 5

    // MARK: - Request Quota

    /// Maximum AI requests allowed within the rolling window.
    static let quotaRequestLimit = 100

    /// Duration of the rolling quota window in seconds (5 hours).
    static let quotaWindowSeconds: TimeInterval = 5 * 60 * 60

    // MARK: - Input Guardrails

    /// Maximum file size in bytes for Session Mode (512 KB).
    static let maxFileSizeBytes = 512 * 1024

    /// Sample size in bytes for binary file detection.
    static let binaryDetectionSampleBytes = 8 * 1024

    /// Maximum characters for captured selected text (Selection + Session).
    static let maxSelectedTextCharacters = 15_000

    /// Maximum characters for OCR output (Screenshot Mode).
    static let maxOCRTextCharacters = 10_000

    // MARK: - Vision (Enhanced Explanation)

    /// Maximum tokens the vision model may generate.
    /// The extraction prompt targets 80-120 tokens. Hard cap at 256
    /// prevents runaway generation while allowing headroom.
    static let maxVisionResponseTokens = 256

    /// Maximum JPEG bytes sent to the vision provider.
    static let maxVisionImageBytes = 800 * 1024  // 800 KB

    /// Timeout for vision extraction (seconds).
    /// Shorter than explanation timeout — visual context is optional enrichment.
    static let visionTimeoutSeconds: TimeInterval = 10

    /// Maximum characters for formatted visual evidence injected into the
    /// explanation prompt. ~150 tokens. Evidence exceeding this is truncated
    /// by dropping lowest-priority (last) items.
    static let maxVisualEvidenceCharacters = 600
}

import CoreGraphics

/// Defines the contract for extracting text from images via OCR.
///
/// Used by Screenshot Mode to extract code from a captured screen region.
/// The concrete implementation uses Apple's Vision framework
/// (`VNRecognizeTextRequest`) for on-device text recognition.
protocol OCRServiceProtocol: Sendable {

    /// Extract text from the given image.
    ///
    /// - Parameter image: The source image to perform OCR on.
    /// - Returns: The recognized text content, or an empty string if no text was found.
    func recognizeText(in image: CGImage) async throws -> String
}

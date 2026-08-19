import Vision
import Foundation

/// Best-effort text extraction from a copied image, via the Vision
/// framework — stateless (no persistence of its own; `ClipboardService`
/// writes the result onto the `ClipboardItem` it's already inserted).
enum ClipboardOCRService {
    /// Runs recognition off the main thread and calls back with the
    /// recognized text (nil if none found or the image couldn't be decoded).
    /// `.fast` recognition level — this is a background pass on every
    /// copied image in a menu-bar tool, not a one-shot user action, so
    /// keeping it cheap matters more than maximum accuracy.
    static func recognizeText(in imageData: Data, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                DispatchQueue.main.async {
                    completion(text.isEmpty ? nil : text)
                }
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: imageData, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}

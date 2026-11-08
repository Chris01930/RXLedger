import UIKit
import Vision

/// Everything produced from one scanned page, ready for the review screen.
struct ScanResult: Identifiable {
    let id = UUID()
    var parse: ParseResult
    var lines: [OCRLine]
    /// Upright (rotation-corrected) color image used for crops.
    var image: UIImage
    /// Downscaled JPEG for storage.
    var imageData: Data?
    var annotations: FieldAnnotations

    var rawText: String { OCRLine.joinedText(lines) }

    var ocrPayload: OCRPayload {
        OCRPayload(rawText: rawText, lines: lines, confidence: parse.meanConfidence, imageData: imageData)
    }
}

enum OCRError: LocalizedError {
    case unreadableImage
    case noText

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "The image couldn't be read."
        case .noText: "No text was found in the image. Try a closer, well-lit photo of the label."
        }
    }
}

/// On-device OCR with Apple Vision. No network access.
struct OCRService {
    var parser = CVSLabelParser()
    /// Below this anchor score, other rotations are tried.
    var uprightScoreThreshold = 8

    /// Raw Vision text recognition on an upright image.
    func recognize(_ cgImage: CGImage) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { obs -> OCRLine? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return OCRLine(text: candidate.string, confidence: Double(candidate.confidence), boundingBox: obs.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            // Keep NDCs, Rx numbers and BINs exactly as printed.
            request.usesLanguageCorrection = false

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Full pipeline: orientation fix → grayscale → OCR (trying rotations if needed) → parse → crops.
    func process(_ image: UIImage) async throws -> ScanResult {
        let upright = ImageProcessing.normalizedOrientation(image)
        guard let color = upright.cgImage else { throw OCRError.unreadableImage }
        let gray = ImageProcessing.grayscale(color)

        var best = (degrees: 0, lines: try await recognize(gray))
        var bestScore = CVSLabelParser.anchorScore(best.lines)

        if bestScore < uprightScoreThreshold {
            for degrees in [90, 180, 270] {
                let lines = try await recognize(ImageProcessing.rotate(gray, degrees: degrees))
                let score = CVSLabelParser.anchorScore(lines)
                if score > bestScore {
                    best = (degrees, lines)
                    bestScore = score
                }
            }
        }

        guard !best.lines.isEmpty else { throw OCRError.noText }

        let rotatedColor = ImageProcessing.rotate(color, degrees: best.degrees)
        let parse = parser.parse(lines: best.lines)

        var annotations = FieldAnnotations(confidence: parse.confidences)
        for key in parse.fields.keys {
            if let box = parse.boundingBox(for: key), let crop = ImageProcessing.crop(rotatedColor, normalizedRect: box) {
                annotations.crops[key] = crop
            }
        }

        return ScanResult(parse: parse,
                          lines: best.lines,
                          image: UIImage(cgImage: rotatedColor),
                          imageData: ImageProcessing.jpegForStorage(rotatedColor),
                          annotations: annotations)
    }
}

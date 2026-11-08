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

    /// Vision output for one orientation.
    struct Recognition {
        var lines: [OCRLine]
        /// Fraction of lines whose text runs upright in the image (0…1).
        var uprightFraction: Double
        /// Clockwise rotation that would make the dominant text upright (0, 90, 180, 270).
        var suggestedRotation: Int
    }

    /// Raw Vision text recognition.
    func recognize(_ cgImage: CGImage) async throws -> Recognition {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                var votes = [0: 0, 90: 0, 180: 0, 270: 0]
                let lines = observations.compactMap { obs -> OCRLine? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    // Direction from the text's bottom edge to its top edge, in image space (y up).
                    let dx = obs.topLeft.x - obs.bottomLeft.x
                    let dy = obs.topLeft.y - obs.bottomLeft.y
                    let rotation: Int
                    if abs(dy) >= abs(dx) {
                        rotation = dy >= 0 ? 0 : 180
                    } else {
                        rotation = dx > 0 ? 270 : 90
                    }
                    votes[rotation, default: 0] += 1
                    return OCRLine(text: candidate.string, confidence: Double(candidate.confidence), boundingBox: obs.boundingBox)
                }
                let total = max(votes.values.reduce(0, +), 1)
                let suggested = votes.max { $0.value < $1.value }?.key ?? 0
                continuation.resume(returning: Recognition(lines: lines,
                                                           uprightFraction: Double(votes[0] ?? 0) / Double(total),
                                                           suggestedRotation: suggested))
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

    /// Full pipeline: orientation fix → grayscale → OCR (rotating until the text is upright and
    /// label anchors are found) → parse → per-field crops.
    func process(_ image: UIImage) async throws -> ScanResult {
        let upright = ImageProcessing.normalizedOrientation(image)
        guard let color = upright.cgImage else { throw OCRError.unreadableImage }
        let gray = ImageProcessing.grayscale(color)

        // Vision can often *read* sideways or upside-down text, but its line geometry then runs in
        // the wrong direction, so the label must be physically upright before parsing.
        func score(_ r: Recognition) -> Double {
            Double(CVSLabelParser.anchorScore(r.lines)) * (0.25 + r.uprightFraction)
        }

        let first = try await recognize(gray)
        var best = (degrees: 0, recognition: first)
        var bestScore = score(first)
        var tried: Set<Int> = [0]

        if first.uprightFraction < 0.7 || CVSLabelParser.anchorScore(first.lines) < uprightScoreThreshold {
            // Try Vision's suggested rotation first, then the rest.
            let order = [first.suggestedRotation, 90, 180, 270].filter { $0 != 0 }
            for degrees in order where !tried.contains(degrees) {
                tried.insert(degrees)
                let r = try await recognize(ImageProcessing.rotate(gray, degrees: degrees))
                let s = score(r)
                if s > bestScore {
                    best = (degrees, r)
                    bestScore = s
                }
                if r.uprightFraction >= 0.7, CVSLabelParser.anchorScore(r.lines) >= uprightScoreThreshold { break }
            }
        }
        var bestLines = best.recognition.lines

        guard !bestLines.isEmpty else { throw OCRError.noText }

        let rotatedColor = ImageProcessing.rotate(color, degrees: best.degrees)
        var parse = parser.parse(lines: bestLines)

        // Vision tends to skip isolated single characters (e.g. a lone "1" in a schedule box).
        // If the schedule header was found but no box values were, re-read that strip at 3x.
        let scheduleKeys: [FieldKey] = [.scheduleMorning, .scheduleMidday, .scheduleEvening, .scheduleBedtime]
        if scheduleKeys.allSatisfy({ parse.fields[$0] == nil }) {
            let extra = await recoverScheduleLines(bestLines, in: ImageProcessing.rotate(gray, degrees: best.degrees))
            if !extra.isEmpty {
                bestLines += extra
                parse = parser.parse(lines: bestLines)
            }
        }

        var annotations = FieldAnnotations(confidence: parse.confidences)
        for key in parse.fields.keys {
            if let box = parse.boundingBox(for: key), let crop = ImageProcessing.crop(rotatedColor, normalizedRect: box) {
                annotations.crops[key] = crop
            }
        }

        return ScanResult(parse: parse,
                          lines: bestLines,
                          image: UIImage(cgImage: rotatedColor),
                          imageData: ImageProcessing.jpegForStorage(rotatedColor),
                          annotations: annotations)
    }

    /// Re-OCRs the strip under the Morning/Midday/Evening/Bedtime header, upscaled, and returns
    /// any new lines mapped back into full-image coordinates.
    func recoverScheduleLines(_ lines: [OCRLine], in image: CGImage) async -> [OCRLine] {
        let words = ["morning", "midday", "evening", "bedtime"]
        let margin: CGFloat = 40
        let header = lines.filter { line in words.contains { line.text.lowercased().contains($0) } }
        guard header.count >= 1,
              Set(header.flatMap { l in words.filter { l.text.lowercased().contains($0) } }).count >= 3,
              let first = header.first else { return [] }
        let box = header.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
        let h = header.map(\.boundingBox.height).max() ?? box.height
        let region = CGRect(x: box.minX - 0.04, y: box.minY - h * 2.4, width: box.width + 0.08, height: h * 2.3)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, region.width > 0, region.height > 0,
              let crop = ImageProcessing.crop(image, normalizedRect: region, padding: 0)?.cgImage,
              let scaled = ImageProcessing.upscale(crop, factor: 3, margin: margin),
              let recognition = try? await recognize(scaled) else { return [] }

        // Undo the margin, then map crop-relative coordinates back into the full image.
        let sw = CGFloat(scaled.width), sh = CGFloat(scaled.height)
        func toCrop(_ v: CGFloat, _ total: CGFloat) -> CGFloat { (v * total - margin) / (total - 2 * margin) }
        return recognition.lines.compactMap { line in
            let b = line.boundingBox
            let x0 = toCrop(b.minX, sw), x1 = toCrop(b.maxX, sw)
            let y0 = toCrop(b.minY, sh), y1 = toCrop(b.maxY, sh)
            let mapped = CGRect(x: region.minX + x0 * region.width,
                                y: region.minY + y0 * region.height,
                                width: (x1 - x0) * region.width,
                                height: (y1 - y0) * region.height)
            // Skip anything the first pass already found.
            let duplicate = lines.contains { $0.boundingBox.intersects(mapped) && $0.text == line.text }
            return duplicate ? nil : OCRLine(text: line.text, confidence: line.confidence, boundingBox: mapped)
        }
    }
}

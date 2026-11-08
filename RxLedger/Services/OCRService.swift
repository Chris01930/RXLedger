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

    /// Several close-up photos of ONE label: each is read at full resolution, the photos are stacked into
    /// one tall image for the record, and the parsed fields are merged.
    func processCloseUps(_ images: [UIImage]) async throws -> ScanResult {
        guard images.count > 1 else { return try await process(images[0]) }
        var pages: [ScanResult] = []
        var lastError: Error?
        for image in images {
            do { pages.append(try await process(image)) } catch { lastError = error }
        }
        guard !pages.isEmpty else { throw lastError ?? OCRError.noText }
        guard pages.count > 1 else { return pages[0] }

        guard let (composite, slots) = ImageProcessing.stackVertically(pages.compactMap(\.image.cgImage)) else {
            throw OCRError.unreadableImage
        }

        var lines: [OCRLine] = []
        var parses: [ParseResult] = []
        for (index, page) in pages.enumerated() {
            let slot = slots[index]
            lines += page.lines.map {
                OCRLine(text: $0.text, confidence: $0.confidence,
                        boundingBox: ImageProcessing.map($0.boundingBox, into: slot), page: index)
            }
            var parse = page.parse
            parse.fields = parse.fields.mapValues { field in
                var f = field
                // Text right at a photo's edge is the most likely to be cut off, so it counts for less
                // when the photos' readings are combined.
                if let first = field.boxes.first {
                    let box = field.boxes.dropFirst().reduce(first) { $0.union($1) }
                    if min(box.minY, 1 - box.maxY) < 0.03 { f.confidence *= 0.7 }
                }
                f.boxes = field.boxes.map { ImageProcessing.map($0, into: slot) }
                return f
            }
            parses.append(parse)
        }
        let merged = CVSLabelParser.merge(parses)

        var annotations = FieldAnnotations(confidence: merged.confidences)
        for key in merged.fields.keys {
            if let box = merged.boundingBox(for: key), let crop = ImageProcessing.crop(composite, normalizedRect: box) {
                annotations.crops[key] = crop
            }
        }
        return ScanResult(parse: merged,
                          lines: lines,
                          image: UIImage(cgImage: composite),
                          // Keep close-up detail: allow a taller stored image than for a single photo.
                          imageData: ImageProcessing.jpegForStorage(composite, maxDimension: 1600 * CGFloat(min(pages.count, 3))),
                          annotations: annotations)
    }

    /// Result of reading an extra photo for an existing scan or record.
    struct SupplementResult {
        /// What the new photo alone yielded (boxes in the composite's coordinates).
        var parse: ParseResult
        /// Existing + new OCR lines, page-tagged, in composite coordinates.
        var lines: [OCRLine]
        /// Existing image with the new photo stacked underneath.
        var image: UIImage
        var imageData: Data?
        var crops: [FieldKey: UIImage]
        /// Confidence of all photos re-parsed together.
        var combinedConfidence: Double?

        var ocrPayload: OCRPayload {
            OCRPayload(rawText: OCRLine.joinedText(lines), lines: lines, confidence: combinedConfidence, imageData: imageData)
        }
    }

    /// Reads one more photo of a label that's already been scanned (or entered), and stacks it with the
    /// existing image so all OCR text stays re-parsable together.
    func supplement(existingImage: UIImage?, existingLines: [OCRLine], with photo: UIImage) async throws -> SupplementResult {
        let page = try await process(photo)
        guard let newImage = page.image.cgImage else { throw OCRError.unreadableImage }
        let existing = existingImage.flatMap { ImageProcessing.normalizedOrientation($0).cgImage }
        guard let (composite, slots) = ImageProcessing.stackVertically([existing, newImage].compactMap { $0 }) else {
            throw OCRError.unreadableImage
        }
        let newSlot = slots.last!

        var lines: [OCRLine] = []
        if !existingLines.isEmpty {
            // Existing lines keep their page tags (single photos become page 0).
            lines = existingLines.map { l in
                OCRLine(text: l.text, confidence: l.confidence,
                        boundingBox: existing != nil ? ImageProcessing.map(l.boundingBox, into: slots[0]) : l.boundingBox,
                        page: l.page ?? 0)
            }
        }
        let newPage = existingLines.isEmpty ? nil : (existingLines.compactMap(\.page).max() ?? 0) + 1
        lines += page.lines.map {
            OCRLine(text: $0.text, confidence: $0.confidence, boundingBox: ImageProcessing.map($0.boundingBox, into: newSlot), page: newPage)
        }

        var parse = page.parse
        parse.fields = parse.fields.mapValues { field in
            var f = field
            f.boxes = field.boxes.map { ImageProcessing.map($0, into: newSlot) }
            return f
        }
        var crops: [FieldKey: UIImage] = [:]
        for key in parse.fields.keys {
            if let box = parse.boundingBox(for: key), let crop = ImageProcessing.crop(composite, normalizedRect: box) {
                crops[key] = crop
            }
        }
        let pageCount = Set(lines.map { $0.page ?? 0 }).count
        return SupplementResult(parse: parse,
                                lines: lines,
                                image: UIImage(cgImage: composite),
                                imageData: ImageProcessing.jpegForStorage(composite, maxDimension: 1600 * CGFloat(min(max(pageCount, 1), 3))),
                                crops: crops,
                                combinedConfidence: parser.parse(pagedLines: lines).meanConfidence)
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
        let rotatedGray = ImageProcessing.rotate(gray, degrees: best.degrees)

        // Small print often comes back as low-confidence garbage; re-read those lines enlarged.
        bestLines = await refineWeakLines(bestLines, in: rotatedGray)
        var parse = parser.parse(lines: bestLines)

        // Vision tends to skip isolated single characters (e.g. a lone "1" in a schedule box).
        // If the schedule header was found but no box values were, re-read that strip at 3x.
        let scheduleKeys: [FieldKey] = [.scheduleMorning, .scheduleMidday, .scheduleEvening, .scheduleBedtime]
        if scheduleKeys.allSatisfy({ parse.fields[$0] == nil }) {
            var extra = await recoverScheduleLines(bestLines, in: rotatedGray)
            extra += await recoverVerticalSchedule(bestLines, in: rotatedGray)
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
        // Only for the horizontal layout (words side by side); the vertical column has its own recovery.
        let mids = header.map(\.boundingBox.midY)
        guard (mids.max() ?? 0) - (mids.min() ?? 0) < (header.map(\.boundingBox.height).max() ?? 0) * 1.5 else { return [] }
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

    /// CVS labels print the schedule as a vertical column (MORNING … BEDTIME) with "SEE DIRECTIONS"
    /// written sideways beside it, which normal OCR misses. Re-read that strip upright and rotated.
    func recoverVerticalSchedule(_ lines: [OCRLine], in image: CGImage) async -> [OCRLine] {
        guard let region = Self.scheduleColumnRegion(lines),
              let crop = ImageProcessing.crop(image, normalizedRect: region, padding: 0)?.cgImage else { return [] }

        var found: [OCRLine] = []
        for degrees in [90, 270] {
            guard let scaled = ImageProcessing.upscale(ImageProcessing.rotate(crop, degrees: degrees), factor: 2),
                  let r = try? await recognize(scaled) else { continue }
            if let hit = r.lines.first(where: { $0.text.uppercased().filter(\.isLetter).contains("SEEDIRECT") }) {
                // Report it as one tall line covering the strip, which the parser treats as sideways text.
                found.append(OCRLine(text: "SEE DIRECTIONS", confidence: hit.confidence, boundingBox: region))
                break
            }
        }
        return found
    }

    /// Where the vertical schedule column's value boxes are: from the schedule word labels when Vision
    /// read at least two, otherwise from the layout (left of the drug text, between the
    /// "Prescription Information" header and the "See back for more information" line).
    static func scheduleColumnRegion(_ lines: [OCRLine]) -> CGRect? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let words = CVSLabelParser.prepare(lines).scheduleWords
        if words.count >= 2 {
            let cells = CVSLabelParser.Context.scheduleCells(from: words)
            let boxes = Array(cells.values)
            if let minY = boxes.map(\.minY).min(), let maxY = boxes.map(\.maxY).max(),
               let right = boxes.map(\.maxX).max(), let h = boxes.map(\.height).max() {
                let r = CGRect(x: right - 0.01, y: minY - h, width: 0.11, height: (maxY - minY) + h * 5).intersection(unit)
                if !r.isNull, r.width > 0, r.height > 0 { return r }
            }
        }
        func find(_ needle: String) -> OCRLine? {
            lines.first { $0.text.uppercased().filter(\.isLetter).contains(needle) }
        }
        guard let header = find("PRESCRIPTIONINFO") else { return nil }
        let bottom = find("SEEBACKFOR")?.boundingBox.maxY ?? find("RECEIPT")?.boundingBox.maxY
        guard let bottom, bottom < header.boundingBox.minY else { return nil }
        // The drug/info column starts noticeably right of the header's left edge.
        let infoX = lines
            .filter { $0.boundingBox.midY < header.boundingBox.minY && $0.boundingBox.midY > bottom
                && $0.boundingBox.minX > header.boundingBox.minX + 0.08 && $0.boundingBox.width > 0.08 }
            .map(\.boundingBox.minX).min()
        guard let infoX else { return nil }
        let left = header.boundingBox.minX + (infoX - header.boundingBox.minX) * 0.45
        let r = CGRect(x: left, y: bottom, width: infoX - left, height: header.boundingBox.minY - bottom).intersection(unit)
        return r.isNull || r.width <= 0 || r.height <= 0 ? nil : r
    }

    /// Re-OCRs low-confidence or squashed lines from an enlarged crop and keeps the better reading.
    func refineWeakLines(_ lines: [OCRLine], in image: CGImage) async -> [OCRLine] {
        let heights = lines.filter { $0.confidence >= 0.5 }.map(\.boundingBox.height).sorted()
        guard !heights.isEmpty else { return lines }
        let medianH = heights[heights.count / 2]
        let main = Set(CVSLabelParser.mainLabelLines(lines).map { $0 })

        var result = lines
        var budget = 30
        for (i, line) in lines.enumerated() where budget > 0 && main.contains(line) {
            let b = line.boundingBox
            guard line.confidence < 0.6 || b.height < medianH * 0.6 else { continue }
            // Schedule labels (MORNING…) sit next to sideways text; re-reading them only adds noise.
            if CVSLabelParser.scheduleSlot(for: line.text) != nil { continue }
            let h = max(b.height, medianH)
            // A fragment lying on top of a line that was already read well is a duplicate, not a new line.
            // Good lines on the same text line as this one; a re-read must not spill into them.
            let neighbours = lines.filter { other in
                other != line && other.confidence >= max(line.confidence, 0.5)
                    && other.boundingBox.height >= medianH * 0.6
                    && abs(other.boundingBox.midY - b.midY) < max(medianH, other.boundingBox.height) * 0.6
            }
            func overlapsNeighbour(_ minX: CGFloat, _ maxX: CGFloat) -> Bool {
                neighbours.contains { minX < $0.boundingBox.maxX - 0.005 && maxX > $0.boundingBox.minX + 0.005 }
            }
            // A fragment lying mostly on a line that was already read well is a duplicate, not a new line.
            let shadowed = neighbours.contains { other in
                let ov = min(b.maxX, other.boundingBox.maxX) - max(b.minX, other.boundingBox.minX)
                return ov > b.width * 0.5
            }
            if shadowed { continue }
            budget -= 1
            // Garbled lines often have a truncated box, so extend well to the right to catch the value.
            let region = CGRect(x: b.minX - 0.015, y: b.midY - h * 1.3, width: max(b.width, 0.1) + 0.1, height: h * 2.6)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !region.isNull, region.width > 0, region.height > 0,
                  let crop = ImageProcessing.crop(image, normalizedRect: region, padding: 0)?.cgImage,
                  let scaled = ImageProcessing.upscale(crop, factor: 3),
                  let r = try? await recognize(scaled) else { continue }
            // Pieces on the crop's centre line (Vision may split "DAYS SUPPLY:" and "28"), mapped back
            // to image coordinates, chained left-to-right from the one under the original box while the
            // gaps stay small — so text from the next column isn't swallowed.
            guard let centre = r.lines.min(by: { abs($0.boundingBox.midY - 0.5) < abs($1.boundingBox.midY - 0.5) }) else { continue }
            let sw = CGFloat(scaled.width), m: CGFloat = 40
            func imageX(_ v: CGFloat) -> CGFloat { region.minX + min(1, max(0, (v * sw - m) / (sw - 2 * m))) * region.width }
            let pieces = r.lines
                .filter { abs($0.boundingBox.midY - centre.boundingBox.midY) < centre.boundingBox.height * 0.5 }
                .map { (line: $0, minX: imageX($0.boundingBox.minX), maxX: imageX($0.boundingBox.maxX)) }
                .sorted { $0.minX < $1.minX }
            guard let startIndex = pieces.indices.min(by: { abs(pieces[$0].minX - b.minX) < abs(pieces[$1].minX - b.minX) }),
                  !overlapsNeighbour(pieces[startIndex].minX, pieces[startIndex].maxX) else { continue }
            var chain = [pieces[startIndex]]
            // A recovered schedule label (e.g. garbled "BEDTIME") stands alone.
            let isScheduleWord = CVSLabelParser.scheduleSlot(for: pieces[startIndex].line.text) != nil
            for p in pieces[(startIndex + 1)...] where !isScheduleWord {
                guard p.minX - chain.last!.maxX <= max(0.04, h * 3), !overlapsNeighbour(p.minX, p.maxX) else { break }
                chain.append(p)
            }
            let text = chain.map(\.line.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let confidence = chain.map(\.line.confidence).reduce(0, +) / Double(chain.count)
            // Squashed boxes are unreliable, so an equally confident re-read of them wins too.
            let squashed = b.height < medianH * 0.6
            guard !text.isEmpty, confidence > line.confidence || (squashed && confidence >= line.confidence) else { continue }
            let minX = chain.first!.minX, maxX = chain.last!.maxX
            result[i] = OCRLine(text: text, confidence: confidence,
                                boundingBox: CGRect(x: minX, y: b.midY - h / 2, width: max(maxX - minX, 0.01), height: h))
        }
        return result
    }
}

import CoreGraphics
import Foundation

/// One line of recognized text. `boundingBox` is in Vision's normalized coordinate space
/// (0…1, origin at the bottom-left of the image).
struct OCRLine: Codable, Equatable, Hashable {
    var text: String
    var confidence: Double
    var boundingBox: CGRect

    init(text: String, confidence: Double, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    /// Converts plain text (one OCR line per text line) into lines with synthetic geometry,
    /// stacked top-to-bottom, full confidence. Used for fixtures and pasted text.
    static func fromPlainText(_ text: String) -> [OCRLine] {
        let rows = text.components(separatedBy: .newlines)
        let count = max(rows.count, 1)
        let height = 1.0 / Double(count)
        return rows.enumerated().compactMap { index, row in
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let y = 1.0 - Double(index + 1) * height
            return OCRLine(text: trimmed, confidence: 1.0,
                           boundingBox: CGRect(x: 0.02, y: y, width: 0.96, height: height * 0.8))
        }
    }

    static func joinedText(_ lines: [OCRLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }
}

import CoreGraphics
import Foundation

/// Pre-filtering of raw OCR lines before row building, based on how real CVS labels photograph:
/// - neighbouring labels partly in frame, cut off at the image edge
/// - the vertical Morning/Midday/Evening/Bedtime column sitting beside the drug text
/// - sideways "SEE DIRECTIONS" text, decorative lines, and tiny low-confidence garbage
extension CVSLabelParser {
    struct Prepared {
        /// Lines used to build rows.
        var lines: [OCRLine]
        /// Schedule word boxes in a vertical layout, by slot (0 Morning … 3 Bedtime).
        var scheduleWords: [Int: CGRect] = [:]
        /// Tall, narrow lines (sideways text), kept aside.
        var verticalLines: [OCRLine] = []
        /// Lines dropped because they belong to another label.
        var droppedNeighbourLines = 0
    }

    static let scheduleWordList = ["MORNING", "MIDDAY", "EVENING", "BEDTIME"]

    /// Decorative text that never carries a field value.
    static let noisePatterns: [NSRegularExpression] = [
        #"PHARMACY\s*ADVI|MACY\s*ADVI|ADVICE\W*$"#,
        #"see\s*back\s*for\s*more"#,
        #"www\.|\.com\b"#,
        // The red "OPEN HERE ▶" tab: as one line or two, arrow read as any stray character.
        #"^\W*(?:[O0]PEN|HERE)(?:\W+(?:[O0]PEN|HERE))?\W*\w?\W*$"#,
    ].map { regex($0) }

    static func prepare(_ input: [OCRLine]) -> Prepared {
        var lines = input.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        var prepared = Prepared(lines: [])

        // 1. Neighbouring labels: text clusters (by x-extent) that touch the left/right image edge
        //    and aren't the biggest cluster.
        let before = lines.count
        lines = mainLabelLines(lines)
        prepared.droppedNeighbourLines = before - lines.count

        let heights = lines.filter { $0.confidence >= 0.5 }.map(\.boundingBox.height).sorted()
        let medianHeight = heights.isEmpty ? 0.02 : heights[heights.count / 2]

        // 2. Schedule words: decide whether they're laid out in a row (keep) or a column (set aside).
        var wordLines: [(slot: Int, index: Int)] = []
        for (i, line) in lines.enumerated() {
            if let slot = scheduleSlot(for: line.text) { wordLines.append((slot, i)) }
        }
        var removeIndexes = Set<Int>()
        if !wordLines.isEmpty {
            let mids = wordLines.map { lines[$0.index].boundingBox.midY }
            let spread = (mids.max() ?? 0) - (mids.min() ?? 0)
            // A lone schedule word, or words stacked vertically, are labels of the icon column.
            if wordLines.count == 1 || spread > medianHeight * 1.5 {
                for w in wordLines where prepared.scheduleWords[w.slot] == nil {
                    prepared.scheduleWords[w.slot] = lines[w.index].boundingBox
                    removeIndexes.insert(w.index)
                }
            }
        }

        for (i, line) in lines.enumerated() where !removeIndexes.contains(i) {
            let box = line.boundingBox
            // 3. Sideways text (tall and narrow).
            if box.height > medianHeight * 2.5, box.height > box.width * 1.3 {
                prepared.verticalLines.append(line)
                continue
            }
            // 4. Tiny, low-confidence fragments with no anchor are OCR garbage from icons and borders.
            if box.height < medianHeight * 0.45, line.confidence < 0.35, !containsAnchor(line.text) {
                continue
            }
            // 5. Decorative lines.
            let range = NSRange(location: 0, length: (line.text as NSString).length)
            if noisePatterns.contains(where: { $0.firstMatch(in: line.text, range: range) != nil }) {
                continue
            }
            prepared.lines.append(line)
        }
        return prepared
    }

    /// Which schedule slot a line names, tolerating OCR errors ("BEOTIME"), or nil.
    static func scheduleSlot(for text: String) -> Int? {
        let letters = text.uppercased().filter(\.isLetter)
        guard (5...9).contains(letters.count) else { return nil }
        for (slot, word) in scheduleWordList.enumerated() where levenshtein(letters, word) <= 2 {
            return slot
        }
        return nil
    }

    static func containsAnchor(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return Anchor.regexes.values.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Keeps the lines of the main label when other labels are partly in frame.
    static func mainLabelLines(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count > 4 else { return lines }
        // Merge x-intervals into clusters.
        let sorted = lines.indices.sorted { lines[$0].boundingBox.minX < lines[$1].boundingBox.minX }
        var clusters: [(minX: Double, maxX: Double, members: [Int], weight: Int)] = []
        for i in sorted {
            let b = lines[i].boundingBox
            if var last = clusters.last, b.minX <= last.maxX + 0.05 {
                last.maxX = max(last.maxX, b.maxX)
                last.members.append(i)
                last.weight += lines[i].text.count
                clusters[clusters.count - 1] = last
            } else {
                clusters.append((b.minX, b.maxX, [i], lines[i].text.count))
            }
        }
        guard clusters.count > 1, let main = clusters.max(by: { $0.weight < $1.weight }) else { return lines }
        var drop = Set<Int>()
        for c in clusters where c.members != main.members {
            let touchesEdge = c.minX < 0.03 || c.maxX > 0.97
            if touchesEdge { drop.formUnion(c.members) }
        }
        return lines.indices.filter { !drop.contains($0) }.map { lines[$0] }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

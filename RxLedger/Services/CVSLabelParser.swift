import CoreGraphics
import Foundation

/// A single parsed value, with where it came from.
struct ParsedField: Equatable {
    var value: String
    var confidence: Double
    /// Normalized Vision boxes of the OCR text the value was read from.
    var boxes: [CGRect]
}

struct ParseResult {
    var fields: [FieldKey: ParsedField] = [:]
    /// Number of distinct anchors and section headers recognized — used to pick the best rotation.
    var anchorScore: Int = 0

    var draft: FillDraft { FillDraft(fields.mapValues(\.value)) }
    var confidences: [FieldKey: Double] { fields.mapValues(\.confidence) }

    /// Mean confidence over fields that were parsed.
    var meanConfidence: Double? {
        guard !fields.isEmpty else { return nil }
        return fields.values.map(\.confidence).reduce(0, +) / Double(fields.count)
    }

    func boundingBox(for key: FieldKey) -> CGRect? {
        guard let boxes = fields[key]?.boxes, let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    subscript(key: FieldKey) -> String? { fields[key]?.value }
}

/// Parses OCR output of a CVS Pharmacy bag-tag label.
///
/// Strategy:
/// 1. Group OCR lines into visual rows (same baseline), ordered top-to-bottom, left-to-right.
/// 2. Find anchor keywords (`RX:`, `NDC:`, `QTY:` …) using OCR-tolerant regexes. A value is the text
///    after an anchor up to the next anchor on the same row, or (if empty) the text directly below.
/// 3. Locate un-anchored fields (patient band, drug lines, directions, schedule, bullets, pharmacy
///    address) by their position relative to section headers.
/// 4. Clean values with field-specific rules that repair common OCR substitutions
///    (`O`→`0`, `l`/`I`→`1`, `S`→`5`, dropped `$`) and validate formats (NDC 5-4-2, dates, money).
///
/// Pure Swift: no UIKit, no Vision. Fully unit-testable with plain-text fixtures.
struct CVSLabelParser {
    init() {}

    func parse(text: String) -> ParseResult {
        parse(lines: OCRLine.fromPlainText(text))
    }

    func parse(lines: [OCRLine]) -> ParseResult {
        var ctx = Context(rows: Self.buildRows(lines))
        ctx.run()
        return ParseResult(fields: ctx.fields, anchorScore: ctx.anchorScore)
    }

    /// How "label-like" a set of lines is. Higher is better.
    static func anchorScore(_ lines: [OCRLine]) -> Int {
        var ctx = Context(rows: buildRows(lines))
        ctx.findHits()
        ctx.findHeaders()
        return ctx.anchorScore
    }

    // MARK: - Rows

    struct Segment {
        let line: OCRLine
        /// UTF-16 offsets within the row text.
        let start: Int
        let end: Int
    }

    struct Row {
        var segments: [Segment]
        var text: String

        var nsText: NSString { text as NSString }

        var confidence: Double {
            guard !segments.isEmpty else { return 0 }
            return segments.map(\.line.confidence).reduce(0, +) / Double(segments.count)
        }

        var box: CGRect {
            segments.dropFirst().reduce(segments.first?.line.boundingBox ?? .zero) { $0.union($1.line.boundingBox) }
        }

        func segments(in range: NSRange) -> [Segment] {
            let hit = segments.filter { $0.end > range.location && $0.start < range.location + max(range.length, 1) }
            return hit.isEmpty ? Array(segments.prefix(1)) : hit
        }

        func boxes(in range: NSRange) -> [CGRect] { segments(in: range).map(\.line.boundingBox) }

        func confidence(in range: NSRange) -> Double {
            let segs = segments(in: range)
            guard !segs.isEmpty else { return confidence }
            return segs.map(\.line.confidence).reduce(0, +) / Double(segs.count)
        }

        /// Approximate horizontal position (0…1) of a UTF-16 offset in the row.
        func x(atOffset offset: Int) -> Double {
            guard let seg = segments.first(where: { offset >= $0.start && offset <= $0.end }) ?? segments.last else { return 0 }
            let len = max(seg.end - seg.start, 1)
            let frac = Double(min(max(offset - seg.start, 0), len)) / Double(len)
            return seg.line.boundingBox.minX + frac * seg.line.boundingBox.width
        }

        func substring(_ range: NSRange) -> String { nsText.substring(with: range) }
    }

    static func buildRows(_ lines: [OCRLine]) -> [Row] {
        let sorted = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var groups: [[OCRLine]] = []
        for line in sorted {
            if var last = groups.last {
                let meanMid = last.map(\.boundingBox.midY).reduce(0, +) / Double(last.count)
                let minHeight = min(line.boundingBox.height, last.map(\.boundingBox.height).min() ?? line.boundingBox.height)
                if abs(line.boundingBox.midY - meanMid) < minHeight * 0.5 {
                    last.append(line)
                    groups[groups.count - 1] = last
                    continue
                }
            }
            groups.append([line])
        }

        return groups.map { group in
            var text = ""
            var segments: [Segment] = []
            for line in group.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
                if !text.isEmpty { text += "  " }
                let start = (text as NSString).length
                text += line.text.trimmingCharacters(in: .whitespaces)
                segments.append(Segment(line: line, start: start, end: (text as NSString).length))
            }
            return Row(segments: segments, text: text)
        }
    }

    // MARK: - Anchors

    enum ColonRule { case required, optionalBeforeDigit, optional }

    enum Anchor: CaseIterable {
        case promised, scripts, dob, storeTel, tel, commonBrands, storeNumber, rx, bin, tp, gr, auth
        case retailPrice, ndc, daw, qty, cap, mfrPkg, refill, mfr, prescriber, daysSupply, dateFilled, amountDue
        case storageType, stickerDate, insuranceInfo

        var literal: String {
            switch self {
            case .promised: "PROMISED"
            case .scripts: "# SCRIPTS"
            case .dob: "DOB"
            case .storeTel: "STORE TEL"
            case .tel: "TEL"
            case .commonBrands: "COMMON BRAND(S)"
            case .storeNumber: "STORE#"
            case .rx: "RX"
            case .bin: "BIN"
            case .tp: "TP"
            case .gr: "GR"
            case .auth: "AUTH#"
            case .retailPrice: "RETAIL PRICE"
            case .ndc: "NDC"
            case .daw: "DAW"
            case .qty: "QTY"
            case .cap: "CAP"
            case .mfrPkg: "MFR PKG"
            case .refill: "REFILL"
            case .mfr: "MFR"
            case .prescriber: "PRSCBR"
            case .daysSupply: "DAYS SUPPLY"
            case .dateFilled: "DATE FILLED"
            case .amountDue: "AMOUNT DUE"
            case .storageType: "DRUG STORAGE TYPE"
            case .stickerDate: "DATE"
            case .insuranceInfo: "INSURANCE INFORMATION"
            }
        }

        var colonRule: ColonRule {
            switch self {
            case .promised, .scripts, .storeNumber, .bin, .auth, .retailPrice, .ndc, .daw, .qty,
                 .daysSupply, .dateFilled, .amountDue, .stickerDate, .dob:
                .optionalBeforeDigit
            case .insuranceInfo:
                .optional
            default:
                .required
            }
        }

        var pattern: String {
            let suffix: String
            switch colonRule {
            case .required: suffix = #"\s*[:;.,]"#
            case .optionalBeforeDigit: suffix = #"(?:\s*[:;.,]|(?=\s+\$?\s*[0-9OoIl]))"#
            case .optional: suffix = #"\s*[:;.,]?"#
            }
            return #"(?<![A-Za-z0-9])"# + CVSLabelParser.fuzzy(literal) + suffix
        }

        static let regexes: [Anchor: NSRegularExpression] = Dictionary(uniqueKeysWithValues: allCases.map {
            ($0, try! NSRegularExpression(pattern: $0.pattern, options: [.caseInsensitive]))
        })
    }

    /// Builds an OCR-tolerant regex for a literal: letters that OCR commonly confuses with digits
    /// accept either, spaces are optional.
    static func fuzzy(_ literal: String) -> String {
        var out = ""
        for ch in literal {
            switch ch {
            case " ": out += #"\s*"#
            case "O": out += "[O0Q]"
            case "I": out += "[I1l|!]"
            case "L": out += "[L1I|]"
            case "S": out += "[S5]"
            case "B": out += "[B8]"
            case "Z": out += "[Z2]"
            case "#": out += #"\s*[#H]?\s*"#
            case "(": out += #"\(?"#
            case ")": out += #"\)?"#
            case "&": out += #"(?:&|AND|8)?"#
            default: out += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return out
    }

    static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    struct Hit {
        let anchor: Anchor
        let row: Int
        /// Range of the anchor keyword itself.
        let anchorRange: NSRange
        /// Range of the inline value (may be empty).
        var valueRange: NSRange
    }

    // MARK: - Value cleaning

    /// Characters OCR commonly produces in place of digits.
    static let permissiveDigit = "[0-9OoQDIil|!SsBZz]"

    /// Replaces look-alike letters with digits. Returns whether any substitution happened.
    static func fixDigits(_ s: String) -> (String, Bool) {
        var changed = false
        let mapped = String(s.map { ch -> Character in
            switch ch {
            case "O", "o", "Q", "D": changed = true; return "0"
            case "I", "i", "l", "|", "!": changed = true; return "1"
            case "S", "s": changed = true; return "5"
            case "B": changed = true; return "8"
            case "Z", "z": changed = true; return "2"
            default: return ch
            }
        })
        return (mapped, changed)
    }

    static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        let re = regex(pattern)
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// Cleaned value plus whether OCR substitutions were needed.
    typealias Cleaned = (value: String, repaired: Bool)

    /// - Parameter requireRealDigit: when true, at least one character must already be a digit so
    ///   ordinary words aren't turned into numbers. Single-character anchored values (DAW) can relax this.
    static func cleanDigits(_ s: String, min: Int = 1, max: Int = 30, requireRealDigit: Bool = true) -> Cleaned? {
        let P = permissiveDigit
        guard let m = firstMatch("(?<![A-Za-z0-9])(\(P){\(min),\(max)})(?![A-Za-z0-9])", in: s)
            ?? firstMatch("(\(P){\(min),\(max)})", in: s) else { return nil }
        let (fixed, changed) = fixDigits(m[1])
        guard fixed.allSatisfy(\.isASCIIDigit), fixed.contains(where: \.isASCIIDigit) else { return nil }
        // Require at least one real digit so plain words aren't turned into numbers.
        guard !requireRealDigit || m[1].contains(where: \.isASCIIDigit) else { return nil }
        return (fixed, changed)
    }

    static func cleanInt(_ s: String) -> Cleaned? {
        guard let d = cleanDigits(s, min: 1, max: 6), let n = Int(d.value) else { return nil }
        return (String(n), d.repaired)
    }

    static func cleanMoney(_ s: String) -> Cleaned? {
        let P = permissiveDigit
        if let m = firstMatch(#"[\$Ss]?\s*("# + P + #"{1,6})\s*[.,]\s*("# + P + #"{2})(?![0-9])"#, in: s) {
            let (whole, c1) = fixDigits(m[1])
            let (cents, c2) = fixDigits(m[2])
            guard whole.allSatisfy(\.isASCIIDigit), cents.allSatisfy(\.isASCIIDigit),
                  let d = LabelFormat.parseMoney("\(whole).\(cents)") else { return nil }
            return (LabelFormat.moneyString(d), c1 || c2 || !s.contains("$"))
        }
        if let m = firstMatch(#"\$\s*("# + P + #"{1,6})(?![0-9.,])"#, in: s) {
            let (whole, c) = fixDigits(m[1])
            guard let d = LabelFormat.parseMoney(whole) else { return nil }
            return (LabelFormat.moneyString(d), c)
        }
        return nil
    }

    static func cleanDate(_ s: String) -> Cleaned? {
        let P = permissiveDigit
        guard let m = firstMatch("(\(P){1,2})\\s*/\\s*(\(P){1,2})\\s*/\\s*(\(P){2,4})", in: s) else { return nil }
        let (mo, c1) = fixDigits(m[1]), (da, c2) = fixDigits(m[2]), (yr, c3) = fixDigits(m[3])
        guard let month = Int(mo), let day = Int(da), let year = Int(yr) else { return nil }
        let yy = year >= 100 ? year % 100 : year
        let str = "\(month)/\(day)/\(String(format: "%02d", yy))"
        guard let date = LabelFormat.parseDate(str) else { return nil }
        return (LabelFormat.formatDate(date), c1 || c2 || c3)
    }

    static func cleanDateTime(_ s: String) -> Cleaned? {
        guard let date = cleanDate(s) else { return nil }
        let P = permissiveDigit
        if let m = firstMatch("(?:/\(P){2,4})[^0-9]*?(\(P){1,2})\\s*[:.]\\s*(\(P){2})\\s*([AaPp])\\.?\\s*[Mm]", in: s) {
            let (h, c1) = fixDigits(m[1]), (mm, c2) = fixDigits(m[2])
            if let hour = Int(h), let minute = Int(mm), (1...12).contains(hour), (0...59).contains(minute) {
                let str = "\(date.value) \(hour):\(String(format: "%02d", minute)) \(m[3].uppercased())M"
                if LabelFormat.parseDateTime(str) != nil {
                    return (str, date.repaired || c1 || c2)
                }
            }
        }
        return date
    }

    static func cleanPhone(_ s: String) -> Cleaned? {
        let P = permissiveDigit
        guard let m = firstMatch(#"\(?\s*("# + P + #"{3})\s*\)?\s*[-.]?\s*("# + P + #"{3})\s*[-.]\s*("# + P + #"{4})"#, in: s) else { return nil }
        let (a, c1) = fixDigits(m[1]), (b, c2) = fixDigits(m[2]), (c, c3) = fixDigits(m[3])
        guard (a + b + c).allSatisfy(\.isASCIIDigit) else { return nil }
        return ("(\(a)) \(b)-\(c)", c1 || c2 || c3)
    }

    static func cleanNDC(_ s: String) -> Cleaned? {
        let P = permissiveDigit
        guard let m = firstMatch("(\(P){4,5})\\s*[-–—~]\\s*(\(P){3,4})\\s*[-–—~]\\s*(\(P){1,2})", in: s) else {
            // 11 digits with no separators.
            if let d = cleanDigits(s, min: 11, max: 11), let formatted = NDC.format542(d.value) {
                return (formatted, d.repaired)
            }
            return nil
        }
        let (a, c1) = fixDigits(m[1]), (b, c2) = fixDigits(m[2]), (c, c3) = fixDigits(m[3])
        guard let normalized = NDC.normalize("\(a)-\(b)-\(c)"), let formatted = NDC.format542(normalized) else { return nil }
        return (formatted, c1 || c2 || c3)
    }

    static func cleanMonthYear(_ s: String) -> Cleaned? {
        let P = permissiveDigit
        guard let m = firstMatch("(\(P){1,2})\\s*/\\s*(\(P){2,4})", in: s) else { return nil }
        let (mo, c1) = fixDigits(m[1]), (yr, c2) = fixDigits(m[2])
        guard let month = Int(mo), (1...12).contains(month), let year = Int(yr) else { return nil }
        return ("\(month)/\(String(format: "%02d", year % 100))", c1 || c2)
    }

    /// Drops leading separator punctuation (left over from an anchor's colon) and collapses spaces.
    /// Trailing punctuation is kept: a trailing comma signals a wrapped line, and notes end in periods.
    static func cleanText(_ s: String) -> String {
        s.replacingOccurrences(of: #"^[\s:;.,]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    static func firstToken(_ s: String) -> String? {
        cleanText(s).split(separator: " ").first.map(String.init)
    }

    // MARK: - Parsing context

    struct Context {
        let rows: [Row]
        var hits: [Hit] = []
        var fields: [FieldKey: ParsedField] = [:]

        var rxInfoHeader: Int?
        var importantHeader: Int?
        var receiptHeader: Int?
        var notesHeader: Int?
        var scheduleHeader: Int?
        var readyFillRow: Int?
        var headersFound = 0

        init(rows: [Row]) { self.rows = rows }

        var anchorScore: Int { Set(hits.map(\.anchor)).count + headersFound }

        mutating func run() {
            findHits()
            findHeaders()
            parseAnchored()
            parseHeaderBlock()
            parsePatientBand()
            parseDrugAndDirections()
            parseSchedule()
            parseImportantInfo()
            parsePharmacy()
            parseInsurancePlan()
            parseNotes()
        }

        // MARK: Hits

        mutating func findHits() {
            hits = []
            for (index, row) in rows.enumerated() {
                let full = NSRange(location: 0, length: row.nsText.length)
                var found: [(Anchor, NSRange)] = []
                for anchor in Anchor.allCases {
                    for m in Anchor.regexes[anchor]!.matches(in: row.text, range: full) {
                        found.append((anchor, m.range))
                    }
                }
                // Earliest first; at the same start, the longest wins. Drop overlaps (e.g. TEL inside STORE TEL).
                found.sort { $0.1.location == $1.1.location ? $0.1.length > $1.1.length : $0.1.location < $1.1.location }
                var kept: [(Anchor, NSRange)] = []
                var lastEnd = 0
                for f in found where f.1.location >= lastEnd {
                    kept.append(f)
                    lastEnd = f.1.location + f.1.length
                }
                for (i, k) in kept.enumerated() {
                    let start = k.1.location + k.1.length
                    let end = i + 1 < kept.count ? kept[i + 1].1.location : full.length
                    hits.append(Hit(anchor: k.0, row: index, anchorRange: k.1,
                                    valueRange: NSRange(location: start, length: max(end - start, 0))))
                }
            }
        }

        func hits(in row: Int) -> [Hit] { hits.filter { $0.row == row } }

        func firstHit(_ anchor: Anchor) -> Hit? { hits.first { $0.anchor == anchor } }

        /// Text before the first anchor on the row (the whole row when it has no anchors).
        func leadingText(_ row: Int) -> String {
            guard rows.indices.contains(row) else { return "" }
            let r = rows[row]
            let end = hits(in: row).map(\.anchorRange.location).min() ?? r.nsText.length
            return CVSLabelParser.cleanText(r.nsText.substring(to: end))
        }

        func leadingRange(_ row: Int) -> NSRange {
            let r = rows[row]
            let end = hits(in: row).map(\.anchorRange.location).min() ?? r.nsText.length
            return NSRange(location: 0, length: end)
        }

        // MARK: Headers

        mutating func findHeaders() {
            func find(_ pattern: String) -> Int? {
                let re = CVSLabelParser.regex(pattern)
                return rows.firstIndex { re.firstMatch(in: $0.text, range: NSRange(location: 0, length: $0.nsText.length)) != nil }
            }
            rxInfoHeader = find(CVSLabelParser.fuzzy("PRESCRIPTION INFO"))
            importantHeader = find(CVSLabelParser.fuzzy("IMPORTANT INFO"))
            receiptHeader = find(CVSLabelParser.fuzzy("RECEIPT") + #"\s*(?:&|and|8)?\s*"# + CVSLabelParser.fuzzy("REFILL INFO"))
                ?? find(CVSLabelParser.fuzzy("RECEIPT") + ".*" + CVSLabelParser.fuzzy("REFILL"))
            notesHeader = find(CVSLabelParser.fuzzy("NOTES FROM"))
            readyFillRow = find(#"(?<![A-Za-z])"# + CVSLabelParser.fuzzy("READY FILL"))
            let words = ["MORNING", "MIDDAY", "EVENING", "BEDTIME"].map { CVSLabelParser.regex(CVSLabelParser.fuzzy($0)) }
            scheduleHeader = rows.firstIndex { row in
                let range = NSRange(location: 0, length: row.nsText.length)
                return words.filter { $0.firstMatch(in: row.text, range: range) != nil }.count >= 3
            }
            headersFound = [rxInfoHeader, importantHeader, receiptHeader, notesHeader, scheduleHeader].compactMap { $0 }.count
        }

        // MARK: Setting fields

        mutating func set(_ key: FieldKey, _ value: String?, row: Int, range: NSRange? = nil, repaired: Bool = false) {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty, fields[key] == nil else { return }
            let r = rows[row]
            let range = range ?? NSRange(location: 0, length: r.nsText.length)
            var conf = r.confidence(in: range)
            if repaired { conf *= 0.85 }
            fields[key] = ParsedField(value: value, confidence: conf, boxes: r.boxes(in: range))
        }

        mutating func set(_ key: FieldKey, _ cleaned: Cleaned?, row: Int, range: NSRange) {
            guard let cleaned else { return }
            set(key, cleaned.value, row: row, range: range, repaired: cleaned.repaired)
        }

        // MARK: Anchored fields

        /// The value for a hit: inline text, or the text directly below when inline is empty.
        func value(for hit: Hit) -> (text: String, row: Int, range: NSRange) {
            let row = rows[hit.row]
            let inline = CVSLabelParser.cleanText(row.substring(hit.valueRange))
            if !inline.isEmpty { return (inline, hit.row, hit.valueRange) }

            let below = hit.row + 1
            guard rows.indices.contains(below), hits(in: below).isEmpty, rowIsFree(below) else {
                return ("", hit.row, hit.valueRange)
            }
            let next = rows[below]
            let anchorX = row.x(atOffset: hit.anchorRange.location)
            let seg = next.segments.min { abs($0.line.boundingBox.minX - anchorX) < abs($1.line.boundingBox.minX - anchorX) }
            guard let seg else { return ("", hit.row, hit.valueRange) }
            let range = NSRange(location: seg.start, length: seg.end - seg.start)
            return (CVSLabelParser.cleanText(next.substring(range)), below, range)
        }

        /// Rows that belong to a section header are not used as "value below".
        func rowIsFree(_ row: Int) -> Bool {
            ![rxInfoHeader, importantHeader, receiptHeader, notesHeader, scheduleHeader].contains(row)
        }

        mutating func parseAnchored() {
            let binRow = firstHit(.bin)?.row ?? firstHit(.gr)?.row ?? firstHit(.insuranceInfo)?.row
            let storageRow = firstHit(.storageType)?.row

            for hit in hits {
                let v = value(for: hit)
                let text = v.text
                switch hit.anchor {
                case .promised: set(.promisedAt, CVSLabelParser.cleanDateTime(text), row: v.row, range: v.range)
                case .scripts: set(.scriptsCount, CVSLabelParser.cleanInt(text), row: v.row, range: v.range)
                case .dob: set(.patientDOB, CVSLabelParser.cleanMonthYear(text), row: v.row, range: v.range)
                case .tel: set(.patientPhone, CVSLabelParser.cleanPhone(text), row: v.row, range: v.range)
                case .storeTel: set(.storePhone, CVSLabelParser.cleanPhone(text), row: v.row, range: v.range)
                case .commonBrands:
                    var brands = text
                    // A trailing comma means the list wraps onto the next line.
                    if brands.hasSuffix(","), rows.indices.contains(v.row + 1), hits(in: v.row + 1).isEmpty {
                        brands += " " + leadingText(v.row + 1)
                    }
                    set(.commonBrands, CVSLabelParser.cleanText(brands), row: v.row, range: v.range)
                case .storeNumber: set(.storeNumber, CVSLabelParser.cleanDigits(text, min: 3, max: 6), row: v.row, range: v.range)
                case .rx: parseRx(text, row: v.row, range: v.range)
                case .bin: set(.bin, CVSLabelParser.cleanDigits(text, min: 5, max: 7), row: v.row, range: v.range)
                case .tp:
                    // TP appears in the insurance block and on the side sticker; assign by proximity.
                    let distBin = binRow.map { abs($0 - hit.row) } ?? Int.max
                    let distSticker = storageRow.map { abs($0 - hit.row) } ?? Int.max
                    let key: FieldKey = (distSticker < distBin && distSticker <= 3) ? .stickerTP : .tp
                    set(key, CVSLabelParser.firstToken(text), row: v.row, range: v.range)
                case .gr: set(.gr, CVSLabelParser.firstToken(text), row: v.row, range: v.range)
                case .auth: set(.authNumber, CVSLabelParser.firstToken(text), row: v.row, range: v.range)
                case .retailPrice: set(.retailPrice, CVSLabelParser.cleanMoney(text), row: v.row, range: v.range)
                case .amountDue: set(.amountDue, CVSLabelParser.cleanMoney(text), row: v.row, range: v.range)
                case .ndc: set(.ndc, CVSLabelParser.cleanNDC(text), row: v.row, range: v.range)
                case .daw: set(.daw, CVSLabelParser.cleanDigits(text, min: 1, max: 1, requireRealDigit: false), row: v.row, range: v.range)
                case .qty: parseQuantity(text, row: v.row, range: v.range)
                case .cap:
                    let lower = text.lowercased()
                    let cap: String? = lower.contains("non") ? "Non-Safety" : (lower.contains("saf") || lower.contains("5af")) ? "Safety" : nil
                    set(.capType, cap, row: v.row, range: v.range)
                case .mfrPkg:
                    let first = text.trimmingCharacters(in: .whitespaces).uppercased().first
                    set(.mfrPackage, first == "Y" ? "Yes" : first == "N" ? "No" : nil, row: v.row, range: v.range)
                case .refill:
                    if text.lowercased().hasPrefix("no") {
                        set(.refillsRemaining, "0", row: v.row, range: v.range)
                    } else {
                        set(.refillsRemaining, CVSLabelParser.cleanInt(text), row: v.row, range: v.range)
                    }
                case .mfr: set(.manufacturer, text, row: v.row, range: v.range)
                case .prescriber: set(.prescriberName, text, row: v.row, range: v.range)
                case .daysSupply: set(.daysSupply, CVSLabelParser.cleanInt(text), row: v.row, range: v.range)
                case .dateFilled: set(.dateFilled, CVSLabelParser.cleanDate(text), row: v.row, range: v.range)
                case .storageType: set(.drugStorageType, text, row: v.row, range: v.range)
                case .stickerDate: set(.stickerDate, CVSLabelParser.cleanDate(text), row: v.row, range: v.range)
                case .insuranceInfo:
                    if !text.isEmpty { set(.insurancePlanName, text, row: v.row, range: v.range) }
                }
            }
        }

        mutating func parseRx(_ text: String, row: Int, range: NSRange) {
            let P = CVSLabelParser.permissiveDigit
            guard let m = CVSLabelParser.firstMatch("^\\s*(\(P){5,10})(?:\\s+(\(P){1,2}))?(?![0-9A-Za-z])", in: text) else { return }
            let (rx, c1) = CVSLabelParser.fixDigits(m[1])
            guard rx.allSatisfy(\.isASCIIDigit) else { return }
            set(.rxNumber, rx, row: row, range: range, repaired: c1)
            if !m[2].isEmpty {
                let (fill, c2) = CVSLabelParser.fixDigits(m[2])
                if fill.allSatisfy(\.isASCIIDigit) {
                    set(.fillNumber, fill.count == 1 ? "0" + fill : fill, row: row, range: range, repaired: c2)
                }
            }
            let rest = String(text.dropFirst(m[0].count))
            if CVSLabelParser.firstMatch(#"(?<![A-Za-z])R\s*F(?![A-Za-z])"#, in: rest) != nil {
                set(.refillFlag, "true", row: row, range: range)
            }
        }

        mutating func parseQuantity(_ text: String, row: Int, range: NSRange) {
            let P = CVSLabelParser.permissiveDigit
            guard let m = CVSLabelParser.firstMatch("(\(P){1,5}(?:[.,]\(P){1,3})?)\\s*([A-Za-z]{1,4})?", in: text) else { return }
            let (q, c) = CVSLabelParser.fixDigits(m[1].replacingOccurrences(of: ",", with: "."))
            guard let qty = Double(q) else { return }
            set(.quantity, LabelFormat.formatNumber(qty), row: row, range: range, repaired: c)
            if !m[2].isEmpty { set(.quantityUnit, m[2].uppercased(), row: row, range: range) }
        }

        // MARK: Header block

        var patientNameRow: Int?

        mutating func parseHeaderBlock() {
            let limit = min(rxInfoHeader ?? rows.count, firstHit(.dob)?.row ?? rows.count, 8, rows.count)
            let P = CVSLabelParser.permissiveDigit

            for i in 0..<min(limit, 5) where fields[.storeCode] == nil {
                let t = leadingText(i)
                if let m = CVSLabelParser.firstMatch("^([A-Za-z]{1,3})\\s+(\(P){1,4})$", in: t) {
                    let (bin, c) = CVSLabelParser.fixDigits(m[2])
                    if bin.allSatisfy(\.isASCIIDigit) {
                        set(.storeCode, m[1].uppercased(), row: i, range: leadingRange(i))
                        set(.binSlot, bin, row: i, range: leadingRange(i), repaired: c)
                    }
                }
            }

            if let r = readyFillRow, r < limit + 3 {
                set(.readyFill, "true", row: r)
            }

            for i in 0..<limit where fields[.barcode] == nil {
                let t = leadingText(i).replacingOccurrences(of: " ", with: "")
                guard t.range(of: "^\(P){8,}$", options: .regularExpression) != nil,
                      t.filter(\.isASCIIDigit).count >= 6 else { continue }
                let (digits, c) = CVSLabelParser.fixDigits(t)
                if digits.allSatisfy(\.isASCIIDigit) {
                    set(.barcode, digits, row: i, range: leadingRange(i), repaired: c)
                }
            }
        }

        // MARK: Patient band

        static let cszPattern = #"^(.*[A-Za-z].*?),?\s+([A-Za-z]{2})\.?\s+("# + CVSLabelParser.permissiveDigit + #"{5}(?:-"# + CVSLabelParser.permissiveDigit + #"{4})?)$"#

        mutating func setCityStateZip(_ t: String, row: Int, keys: (FieldKey, FieldKey, FieldKey)) -> Bool {
            guard let m = CVSLabelParser.firstMatch(Self.cszPattern, in: t) else { return false }
            let (zip, c) = CVSLabelParser.fixDigits(m[3])
            guard zip.replacingOccurrences(of: "-", with: "").allSatisfy(\.isASCIIDigit) else { return false }
            set(keys.0, CVSLabelParser.cleanText(m[1]).trimmingCharacters(in: CharacterSet(charactersIn: ",")), row: row, range: leadingRange(row))
            set(keys.1, m[2].uppercased(), row: row, range: leadingRange(row))
            set(keys.2, zip, row: row, range: leadingRange(row), repaired: c)
            return true
        }

        mutating func parsePatientBand() {
            let dobRow = firstHit(.dob)?.row ?? firstHit(.tel)?.row
            let limit = min(dobRow ?? rxInfoHeader ?? min(12, rows.count), rows.count)
            let namePattern = #"^[A-Za-z][A-Za-z'\-\.]*(?:\s+[A-Za-z'\-\.]+)*\s*,\s*[A-Za-z][A-Za-z'\-\.]*(?:\s+[A-Za-z]\.?)*$"#

            guard let nameRow = (0..<limit).first(where: { i in
                i != readyFillRow && leadingText(i).range(of: namePattern, options: .regularExpression) != nil
            }) else { return }
            patientNameRow = nameRow
            set(.patientName, leadingText(nameRow), row: nameRow, range: leadingRange(nameRow))

            let end = min((dobRow ?? nameRow + 3) + 1, rows.count)
            for i in (nameRow + 1)..<max(end, nameRow + 1) {
                let t = leadingText(i)
                guard !t.isEmpty else { continue }
                if fields[.patientStreet] == nil, t.first?.isASCIIDigit == true, t.contains(where: \.isLetter),
                   CVSLabelParser.firstMatch(Self.cszPattern, in: t) == nil {
                    set(.patientStreet, t, row: i, range: leadingRange(i))
                } else if fields[.patientCity] == nil {
                    _ = setCityStateZip(t, row: i, keys: (.patientCity, .patientState, .patientZip))
                }
            }
        }

        // MARK: Drug lines and directions

        static let directionVerbs = #"^(take|apply|use|inhale|instill|place|dissolve|chew|insert|inject|spray|give|swallow|mix|rub|shake)\b"#

        mutating func parseDrugAndDirections() {
            let brandsRow = firstHit(.commonBrands)?.row
            let start: Int
            if let h = rxInfoHeader {
                start = h + 1
            } else if let telRow = firstHit(.tel)?.row ?? firstHit(.dob)?.row {
                start = telRow + 1
            } else if let b = brandsRow {
                start = max(b - 2, 0)
            } else {
                return
            }
            let directionsStartRow = (start..<min(start + 5, rows.count)).first {
                leadingText($0).range(of: Self.directionVerbs, options: [.regularExpression, .caseInsensitive]) != nil
            }
            let end = min(brandsRow ?? directionsStartRow ?? start + 2, rows.count)

            let candidates = (start..<max(end, start)).filter { i in
                !leadingText(i).isEmpty && hits(in: i).isEmpty && i != scheduleHeader
            }
            if candidates.count >= 2 {
                set(.drugName, leadingText(candidates[0]), row: candidates[0], range: leadingRange(candidates[0]))
                set(.strengthForm, leadingText(candidates[1]), row: candidates[1], range: leadingRange(candidates[1]))
            } else if let only = candidates.first {
                let t = leadingText(only)
                let strength = #"\s(\d+(?:\.\d+)?\s*(?:MG|MCG|G|ML|%|UNITS?|MEQ|IU)\b.*)$"#
                if let m = CVSLabelParser.firstMatch(strength, in: t) {
                    set(.drugName, String(t.dropLast(m[0].count)).trimmingCharacters(in: .whitespaces), row: only, range: leadingRange(only))
                    set(.strengthForm, m[1], row: only, range: leadingRange(only))
                } else {
                    set(.drugName, t, row: only, range: leadingRange(only))
                }
            }

            // Directions: after the brands line (skipping a wrapped brands line) until the schedule or bullets.
            var dStart = brandsRow.map { $0 + 1 } ?? directionsStartRow ?? (candidates.last.map { $0 + 1 } ?? start)
            if let b = brandsRow, let brands = fields[.commonBrands]?.value, rows.indices.contains(b + 1),
               !leadingText(b + 1).isEmpty, brands.hasSuffix(leadingText(b + 1)) {
                dStart = b + 2
            }
            let stops = [scheduleHeader, importantHeader, receiptHeader].compactMap { $0 }.filter { $0 >= dStart }
            let dEnd = min(stops.min() ?? dStart + 3, rows.count)
            var parts: [String] = []
            var firstRow: Int?
            for i in dStart..<max(dEnd, dStart) where hits(in: i).isEmpty {
                let t = leadingText(i)
                guard !t.isEmpty else { continue }
                parts.append(t)
                if firstRow == nil { firstRow = i }
            }
            if let firstRow, !parts.isEmpty {
                set(.directions, parts.joined(separator: " "), row: firstRow)
            }
        }

        // MARK: Schedule boxes

        mutating func parseSchedule() {
            guard let header = scheduleHeader else { return }
            let keys: [FieldKey] = [.scheduleMorning, .scheduleMidday, .scheduleEvening, .scheduleBedtime]
            let see = CVSLabelParser.regex(CVSLabelParser.fuzzy("SEE DIRECTIONS"))
            for i in max(header - 1, 0)...min(header + 2, rows.count - 1) {
                let row = rows[i]
                if see.firstMatch(in: row.text, range: NSRange(location: 0, length: row.nsText.length)) != nil {
                    for k in keys { set(k, "SEE DIRECTIONS", row: i) }
                    return
                }
            }

            // Column centers from the header words.
            let headerRow = rows[header]
            let words = ["MORNING", "MIDDAY", "EVENING", "BEDTIME"]
            var centers: [Double] = []
            for (idx, w) in words.enumerated() {
                let re = CVSLabelParser.regex(CVSLabelParser.fuzzy(w))
                if let m = re.firstMatch(in: headerRow.text, range: NSRange(location: 0, length: headerRow.nsText.length)) {
                    centers.append(headerRow.x(atOffset: m.range.location + m.range.length / 2))
                } else {
                    centers.append(headerRow.box.minX + headerRow.box.width * (Double(idx) + 0.5) / 4)
                }
            }

            let valueRowIndex = header + 1
            guard rows.indices.contains(valueRowIndex), valueRowIndex != importantHeader, hits(in: valueRowIndex).isEmpty else { return }
            let valueRow = rows[valueRowIndex]
            let tokenRe = CVSLabelParser.regex(#"\S+"#)
            let tokens = tokenRe.matches(in: valueRow.text, range: NSRange(location: 0, length: valueRow.nsText.length))
            // Only short quantity-like tokens ("1", "1/2", "2 TABS" fragments) belong in the boxes.
            guard !tokens.isEmpty, tokens.count <= 8,
                  tokens.allSatisfy({ valueRow.substring($0.range).count <= 6 }) else { return }

            var assigned: [Int: [String]] = [:]
            for t in tokens {
                let x = valueRow.x(atOffset: t.range.location + t.range.length / 2)
                let col = centers.enumerated().min { abs($0.element - x) < abs($1.element - x) }!.offset
                assigned[col, default: []].append(valueRow.substring(t.range))
            }
            for (col, values) in assigned {
                set(keys[col], values.joined(separator: " "), row: valueRowIndex)
            }
        }

        // MARK: Important information bullets

        mutating func parseImportantInfo() {
            guard let header = importantHeader else { return }
            let end = min([receiptHeader, notesHeader].compactMap { $0 }.filter { $0 > header }.min() ?? header + 10, rows.count)
            var items: [String] = []
            let bullet = #"^\s*[•·●▪◦\-\*]\s*"#
            for i in (header + 1)..<max(end, header + 1) where hits(in: i).isEmpty {
                let raw = rows[i].text
                let t = CVSLabelParser.cleanText(raw)
                guard !t.isEmpty else { continue }
                if raw.range(of: bullet, options: .regularExpression) != nil || items.isEmpty {
                    items.append(raw.replacingOccurrences(of: bullet, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces))
                } else {
                    items[items.count - 1] += " " + t
                }
            }
            if !items.isEmpty {
                set(.importantInfo, items.joined(separator: "\n"), row: header + 1)
            }
        }

        // MARK: Pharmacy

        mutating func parsePharmacy() {
            let start: Int
            if let h = receiptHeader {
                start = h + 1
            } else if let r = rows.indices.first(where: { $0 > (rxInfoHeader ?? 0) && leadingText($0).range(of: "cvs", options: .caseInsensitive) != nil }) {
                start = r
            } else {
                return
            }
            let end = min(start + 6, rows.count)
            var nameRow: Int?
            for i in start..<max(end, start) {
                let t = leadingText(i)
                guard !t.isEmpty else { continue }
                if nameRow == nil {
                    if t.first?.isASCIIDigit == false, CVSLabelParser.firstMatch(Self.cszPattern, in: t) == nil {
                        nameRow = i
                        set(.pharmacyName, t, row: i, range: leadingRange(i))
                    }
                    continue
                }
                if fields[.pharmacyStreet] == nil, t.first?.isASCIIDigit == true, CVSLabelParser.firstMatch(Self.cszPattern, in: t) == nil {
                    set(.pharmacyStreet, t, row: i, range: leadingRange(i))
                } else if fields[.pharmacyCity] == nil, setCityStateZip(t, row: i, keys: (.pharmacyCity, .pharmacyState, .pharmacyZip)) {
                    break
                }
            }
        }

        mutating func parseInsurancePlan() {
            guard fields[.insurancePlanName] == nil, let hit = firstHit(.insuranceInfo) else { return }
            let next = hit.row + 1
            guard rows.indices.contains(next) else { return }
            let t = leadingText(next)
            if !t.isEmpty { set(.insurancePlanName, t, row: next, range: leadingRange(next)) }
        }

        // MARK: Notes

        mutating func parseNotes() {
            guard let header = notesHeader else { return }
            var parts: [String] = []
            var firstRow: Int?
            for i in (header + 1)..<max(rows.count, header + 1) {
                if !hits(in: i).isEmpty { break }
                let t = leadingText(i)
                guard !t.isEmpty else { continue }
                parts.append(t)
                if firstRow == nil { firstRow = i }
            }
            if let firstRow { set(.pharmacyNotes, parts.joined(separator: " "), row: firstRow) }
        }
    }
}

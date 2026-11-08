import Foundation

/// National Drug Code helpers.
///
/// NDCs are printed as 10 digits in one of three segment layouts (4-4-2, 5-3-2, 5-4-1) or,
/// as on CVS labels, already padded to the 11-digit 5-4-2 layout. Normalizing pads the short
/// segment with a leading zero to get the 11-digit HIPAA form.
enum NDC {
    /// Returns the 11-digit normalized NDC, or nil if the input isn't a recognizable NDC.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let segments = trimmed
            .split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "–" })
            .map(String.init)

        guard segments.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }

        if segments.count == 1 {
            // Bare 11 digits is unambiguous; a bare 10-digit code is not.
            return segments[0].count == 11 ? segments[0] : nil
        }

        guard segments.count == 3 else { return nil }
        let (a, b, c) = (segments[0], segments[1], segments[2])
        switch (a.count, b.count, c.count) {
        case (5, 4, 2): return a + b + c
        case (4, 4, 2): return "0" + a + b + c
        case (5, 3, 2): return a + "0" + b + c
        case (5, 4, 1): return a + b + "0" + c
        default: return nil
        }
    }

    /// Formats an 11-digit NDC as 5-4-2 ("00093-1048-01").
    static func format542(_ normalized: String?) -> String? {
        guard let n = normalized, n.count == 11, n.allSatisfy(\.isASCIIDigit) else { return nil }
        let chars = Array(n)
        return String(chars[0..<5]) + "-" + String(chars[5..<9]) + "-" + String(chars[9..<11])
    }

    /// True when the string is exactly ddddd-dddd-dd.
    static func isValid542(_ string: String?) -> Bool {
        guard let string else { return false }
        return string.range(of: #"^\d{5}-\d{4}-\d{2}$"#, options: .regularExpression) != nil
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

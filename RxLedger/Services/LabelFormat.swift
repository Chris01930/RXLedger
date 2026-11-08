import Foundation

/// Date, money and number formatting that matches the CVS label.
/// All label dates are interpreted and displayed in America/New_York so a fill dated 6/23/26
/// never shows as 6/22/26 on a device set to another time zone.
enum LabelFormat {
    static let timeZone = TimeZone(identifier: "America/New_York")!
    static let posix = Locale(identifier: "en_US_POSIX")

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = posix
        return c
    }()

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = posix
        f.timeZone = timeZone
        f.dateFormat = format
        f.isLenient = false
        // Two-digit years map to 2000–2099.
        f.twoDigitStartDate = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))
        return f
    }

    private static let shortDate = makeFormatter("M/d/yy")
    private static let longYearDate = makeFormatter("M/d/yyyy")
    private static let dateTimeFormats = ["M/d/yy h:mm a", "M/d/yy, h:mm a", "M/d/yy h:mma", "M/d/yyyy h:mm a"].map(makeFormatter)
    private static let dateTimeOut = makeFormatter("M/d/yy h:mm a")
    private static let mediumDate = makeFormatter("MMM d, yyyy")
    private static let isoDay = makeFormatter("yyyy-MM-dd")

    // MARK: Dates

    static func parseDate(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 3, parts[2].count == 4 { return longYearDate.date(from: s) }
        return shortDate.date(from: s)
    }

    static func parseDateTime(_ string: String) -> Date? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(\\d)(AM|PM)", with: "$1 $2", options: .regularExpression)
        guard !s.isEmpty else { return nil }
        for f in dateTimeFormats {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// "6/23/26"
    static func formatDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return shortDate.string(from: date)
    }

    /// "6/23/26 3:00 PM"
    static func formatDateTime(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateTimeOut.string(from: date)
    }

    /// "Jun 23, 2026"
    static func formatMedium(_ date: Date?) -> String {
        guard let date else { return "—" }
        return mediumDate.string(from: date)
    }

    /// "2026-06-23" (used in dedupe keys and exports)
    static func formatISODay(_ date: Date?) -> String {
        guard let date else { return "" }
        return isoDay.string(from: date)
    }

    static func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    // MARK: Money

    /// Accepts "12.34", "$12.34", "1,234.50", "12". Returns nil for anything else.
    static func parseMoney(_ string: String) -> Decimal? {
        let s = string
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: s, locale: posix)
    }

    /// "12.34" — plain string for editable drafts.
    static func moneyString(_ value: Decimal?) -> String {
        guard let value else { return "" }
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 2, .plain)
        let n = NSDecimalNumber(decimal: rounded)
        let f = NumberFormatter()
        f.locale = posix
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.minimumIntegerDigits = 1
        return f.string(from: n) ?? "\(rounded)"
    }

    /// "$12.34"
    static func formatMoney(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return "$" + moneyString(value)
    }

    // MARK: Numbers

    /// "30", "2.5"
    static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e12 { return String(Int(value)) }
        let f = NumberFormatter()
        f.locale = posix
        f.maximumFractionDigits = 3
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

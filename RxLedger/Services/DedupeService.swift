import Foundation
import SwiftData

/// Duplicate-fill detection.
///
/// - Primary key: `rxNumber-fillNumber` (e.g. "2581363-01"), which uniquely identifies one CVS fill.
/// - Fallback: `normalizedNDC-yyyy-MM-dd` of the date filled.
/// - Neither available: the fill gets a random `unkeyed-<uuid>` key and is never treated as a duplicate.
enum DedupeService {
    static func key(rxNumber: String?, fillNumber: String?, ndc: String?, dateFilled: Date?) -> String? {
        let rx = digits(rxNumber)
        let fill = digits(fillNumber)
        if !rx.isEmpty, !fill.isEmpty {
            let paddedFill = fill.count == 1 ? "0" + fill : fill
            return "\(rx)-\(paddedFill)"
        }
        if let normalized = NDC.normalize(ndc), let dateFilled {
            return "\(normalized)-\(LabelFormat.formatISODay(dateFilled))"
        }
        return nil
    }

    static func key(for draft: FillDraft) -> String? {
        key(rxNumber: draft.text(.rxNumber),
            fillNumber: draft.text(.fillNumber),
            ndc: draft.text(.ndc),
            dateFilled: draft.date(.dateFilled))
    }

    /// True when the draft can only be de-duplicated by NDC + date (no Rx/fill number).
    static func usesFallback(_ draft: FillDraft) -> Bool {
        digits(draft.text(.rxNumber)).isEmpty || digits(draft.text(.fillNumber)).isEmpty
    }

    static func isUnkeyed(_ key: String) -> Bool { key.hasPrefix("unkeyed-") || key.isEmpty }

    /// Finds an existing fill with the same key, optionally ignoring one fill (the one being edited).
    static func findExisting(key: String?, in context: ModelContext, excluding excludedID: UUID? = nil) -> Fill? {
        guard let key, !isUnkeyed(key) else { return nil }
        let descriptor = FetchDescriptor<Fill>(predicate: #Predicate { $0.dedupeKey == key })
        let matches = (try? context.fetch(descriptor)) ?? []
        return matches.first { $0.id != excludedID }
    }

    /// "Rx 2581363, fill 01, 6/23/26"
    static func describe(_ fill: Fill) -> String {
        var parts: [String] = []
        if let rx = fill.rxNumber { parts.append("Rx \(rx)") }
        if let f = fill.fillNumber { parts.append("fill \(f)") }
        if parts.isEmpty, let ndc = fill.ndc { parts.append("NDC \(ndc)") }
        if let d = fill.dateFilled { parts.append(LabelFormat.formatDate(d)) }
        return parts.isEmpty ? fill.displayName : parts.joined(separator: ", ")
    }

    static func digits(_ s: String?) -> String {
        (s ?? "").filter(\.isASCIIDigit)
    }
}

import Foundation
import UIKit

/// A field where an added photo read something different from the value already in the form.
struct FieldConflict: Identifiable {
    enum CurrentSource: Equatable {
        /// Read by OCR from an earlier photo, with that reading's confidence.
        case scan(confidence: Double)
        /// Changed by hand (in this session or before).
        case edited
        /// Typed in a manual entry; no earlier OCR to compare with.
        case entered

        var description: String {
            switch self {
            case .scan(let c): "Original scan · \(Int((c * 100).rounded()))%"
            case .edited: "Edited by hand"
            case .entered: "Entered manually"
            }
        }
    }

    let key: FieldKey
    let currentValue: String
    let currentSource: CurrentSource
    var currentCrop: UIImage?
    let newValue: String
    let newConfidence: Double
    var newCrop: UIImage?

    var id: FieldKey { key }

    /// Pre-selected choice: the new reading only when it's clearly more confident than an earlier
    /// OCR reading. Values typed by hand are kept by default.
    var prefersNew: Bool {
        if case .scan(let c) = currentSource { return newConfidence > c + 0.05 }
        return false
    }

    /// Compares a new photo's readings with the form.
    /// - Parameters:
    ///   - draft: what the form shows now.
    ///   - baseline: what OCR put in the form this session (differences from `draft` are the user's edits).
    ///   - previous: earlier photos re-parsed, if there were any.
    ///   - new: the added photo's readings.
    static func detect(draft: FillDraft, baseline: FillDraft, previous: ParseResult?, new: ParseResult) -> [FieldConflict] {
        var conflicts: [FieldConflict] = []
        for key in FieldKey.allCases {
            guard let current = draft.text(key), let newField = new.fields[key],
                  !sameValue(current, newField.value, kind: key.kind) else { continue }
            // A partial list or note (part of the label out of frame) isn't a disagreement.
            if key.kind == .list || key.kind == .multiline,
               normalized(current).contains(normalized(newField.value)) { continue }

            let source: CurrentSource
            if draft.text(key) != baseline.text(key) {
                source = .edited
            } else if let prev = previous?.fields[key], sameValue(prev.value, current, kind: key.kind) {
                source = .scan(confidence: prev.confidence)
            } else if previous == nil {
                source = .entered
            } else {
                source = .edited
            }
            conflicts.append(FieldConflict(key: key, currentValue: current, currentSource: source,
                                           newValue: newField.value, newConfidence: newField.confidence))
        }
        return conflicts
    }

    static func sameValue(_ a: String, _ b: String, kind: FieldKind) -> Bool {
        switch kind {
        case .money:
            if let x = LabelFormat.parseMoney(a), let y = LabelFormat.parseMoney(b) { return x == y }
        case .date:
            if let x = LabelFormat.parseDate(a), let y = LabelFormat.parseDate(b) { return x == y }
        case .dateTime:
            if let x = LabelFormat.parseDateTime(a), let y = LabelFormat.parseDateTime(b) { return x == y }
        case .ndc:
            if let x = NDC.normalize(a), let y = NDC.normalize(b) { return x == y }
        case .integer, .decimal:
            if let x = Double(a.trimmingCharacters(in: .whitespaces)), let y = Double(b.trimmingCharacters(in: .whitespaces)) { return x == y }
        default:
            break
        }
        return normalized(a) == normalized(b)
    }

    /// Case-, spacing- and trailing-punctuation-insensitive form.
    static func normalized(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:")))
    }
}

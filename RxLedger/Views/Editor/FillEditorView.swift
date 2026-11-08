import SwiftData
import SwiftUI
import UIKit

/// Per-field OCR annotations shown in review mode.
struct FieldAnnotations {
    var confidence: [FieldKey: Double] = [:]
    /// Cropped strip of the OCR line(s) each field was read from.
    var crops: [FieldKey: UIImage] = [:]
}

enum EditorPurpose {
    /// New fill from a manual entry or a reviewed scan.
    case create(source: DataSource, ocr: OCRPayload?)
    /// Edit an existing fill.
    case update(Fill)
    /// Apply a fresh parse of an existing fill's stored OCR text.
    case reparse(Fill, confidence: Double?)

    var existingFill: Fill? {
        switch self {
        case .create: nil
        case .update(let f), .reparse(let f, _): f
        }
    }
}

enum EditorResult {
    case saved(Fill)
    case viewExisting(Fill)
    case cancelled
}

/// The single form used for manual entry, scan review, editing and re-parsing.
/// Handles validation and duplicate detection, then reports back via `onFinish`.
struct FillEditorView: View {
    @Environment(\.modelContext) private var context

    let title: String
    let purpose: EditorPurpose
    /// Values the form started from (parser output for scans) — used to detect user edits.
    let baseline: FillDraft
    var annotations: FieldAnnotations?
    /// Shown as a subtitle, e.g. "Label 2 of 3".
    var progressText: String?
    var cancelTitle: String = "Cancel"
    let onFinish: (EditorResult) -> Void

    @State private var draft: FillDraft
    @State private var issues: [FieldKey: String] = [:]
    @State private var duplicate: Fill?
    @State private var editConflict: Fill?
    @State private var errorMessage: String?

    init(title: String,
         initialDraft: FillDraft,
         baseline: FillDraft? = nil,
         purpose: EditorPurpose,
         annotations: FieldAnnotations? = nil,
         progressText: String? = nil,
         cancelTitle: String = "Cancel",
         onFinish: @escaping (EditorResult) -> Void) {
        self.title = title
        self.purpose = purpose
        self.baseline = baseline ?? initialDraft
        self.annotations = annotations
        self.progressText = progressText
        self.cancelTitle = cancelTitle
        self.onFinish = onFinish
        _draft = State(initialValue: initialDraft)
    }

    private var isScanSource: Bool {
        switch purpose {
        case .create(let source, _): source == .scan
        case .update(let f), .reparse(let f, _): f.source == .scan
        }
    }

    private var showsFallbackWarning: Bool {
        !draft.isEmpty && DedupeService.usesFallback(draft)
    }

    var body: some View {
        FillFormView(draft: $draft,
                     baseline: baseline,
                     annotations: annotations,
                     issues: issues,
                     header: { headerContent })
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelTitle) { onFinish(.cancelled) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(draft.text(.drugName) == nil)
                }
            }
            .onChange(of: draft) { _, newDraft in
                // Clear issues as soon as the user fixes them.
                guard !issues.isEmpty else { return }
                let current = newDraft.validationIssues()
                issues = issues.filter { current[$0.key] != nil }
            }
            .sheet(item: $duplicate) { existing in
                DuplicateFillSheet(existing: existing,
                                   isScan: isScanSource,
                                   onViewExisting: {
                                       duplicate = nil
                                       onFinish(.viewExisting(existing))
                                   },
                                   onReplace: {
                                       duplicate = nil
                                       replace(existing)
                                   },
                                   onCancel: { duplicate = nil })
                    .presentationDetents([.medium])
            }
            .alert("Another fill already uses this Rx and fill number",
                   isPresented: Binding(get: { editConflict != nil }, set: { if !$0 { editConflict = nil } }),
                   presenting: editConflict) { other in
                Button("View Existing") { onFinish(.viewExisting(other)) }
                Button("Keep Editing", role: .cancel) {}
            } message: { other in
                Text("\(DedupeService.describe(other)) is already recorded. Change the Rx/fill number or date, or delete the other fill first.")
            }
            .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder
    private var headerContent: some View {
        if let progressText {
            Text(progressText).font(.subheadline.weight(.semibold))
        }
        if annotations != nil {
            Label("Check every field against the label. Blank fields couldn't be read; tinted fields show OCR confidence.",
                  systemImage: "checklist")
                .font(.footnote)
        }
        if case .reparse = purpose {
            Label("These values come from re-running the parser on the stored OCR text. Review, then save to replace the current values.",
                  systemImage: "arrow.clockwise")
                .font(.footnote)
        }
        if showsFallbackWarning {
            Label("No Rx number and fill number — duplicate detection will fall back to NDC + date filled.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if !issues.isEmpty {
            Label("Fix the highlighted fields before saving.", systemImage: "xmark.octagon")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    // MARK: - Saving

    private var wasEdited: Bool { !draft.changedKeys(comparedTo: baseline).isEmpty }

    private func save() {
        let found = draft.validationIssues()
        guard found.isEmpty else {
            issues = found
            return
        }
        let key = DedupeService.key(for: draft)
        let existing = DedupeService.findExisting(key: key, in: context, excluding: purpose.existingFill?.id)

        do {
            let repo = FillRepository(context: context)
            switch purpose {
            case .create(let source, let ocr):
                if let existing {
                    duplicate = existing
                    return
                }
                let fill = try repo.create(from: draft, source: source, ocr: ocr, wasEditedAfterScan: wasEdited)
                onFinish(.saved(fill))
            case .update(let fill):
                if let existing {
                    editConflict = existing
                    return
                }
                try repo.update(fill, with: draft)
                onFinish(.saved(fill))
            case .reparse(let fill, let confidence):
                if let existing {
                    editConflict = existing
                    return
                }
                fill.apply(draft)
                fill.ocrConfidence = confidence ?? fill.ocrConfidence
                fill.wasEditedAfterScan = wasEdited
                repo.link(fill)
                repo.cleanupOrphanMedications()
                try context.save()
                onFinish(.saved(fill))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replace(_ existing: Fill) {
        guard case .create(let source, let ocr) = purpose else { return }
        do {
            let fill = try FillRepository(context: context)
                .replace(existing, with: draft, source: source, ocr: ocr, wasEditedAfterScan: wasEdited)
            onFinish(.saved(fill))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// "This fill is already recorded" sheet.
struct DuplicateFillSheet: View {
    let existing: Fill
    let isScan: Bool
    let onViewExisting: () -> Void
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Already Recorded")
                .font(.title2.bold())
            Text("This fill is already recorded (\(DedupeService.describe(existing))).")
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button(action: onViewExisting) {
                    Text("View Existing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive, action: onReplace) {
                    Text(isScan ? "Replace with This Scan" : "Replace with This Entry").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button("Cancel", role: .cancel, action: onCancel)
                    .padding(.top, 4)
            }
            .controlSize(.large)
        }
        .padding(24)
    }
}

#Preview("Manual entry") {
    NavigationStack {
        FillEditorView(title: "Add Manually", initialDraft: FillDraft(), purpose: .create(source: .manual, ocr: nil)) { _ in }
    }
    .modelContainer(PersistenceController.preview)
}

#Preview("Review") {
    var draft = SampleData.metforminDraft
    draft[.authNumber] = ""
    return NavigationStack {
        FillEditorView(title: "Review Scan", initialDraft: draft,
                       purpose: .create(source: .scan, ocr: nil),
                       annotations: FieldAnnotations(confidence: [.drugName: 0.95, .ndc: 0.62, .amountDue: 0.31, .rxNumber: 0.9]),
                       progressText: "Label 1 of 2") { _ in }
    }
    .modelContainer(PersistenceController.preview)
}

#Preview("Duplicate sheet") {
    DuplicateFillSheet(existing: SampleData.previewFill(), isScan: true, onViewExisting: {}, onReplace: {}, onCancel: {})
        .modelContainer(PersistenceController.preview)
}

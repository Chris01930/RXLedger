import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import VisionKit

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
/// Where an extra photo comes from.
enum PhotoSource {
    case camera, library
}

struct FillEditorView: View {
    @Environment(\.modelContext) private var context

    let title: String
    let purpose: EditorPurpose
    /// Shown as a subtitle, e.g. "Label 2 of 3".
    var progressText: String?
    var cancelTitle: String = "Cancel"
    /// Open the camera or photo picker right away (used by "Add Photo for Missing Fields" on a record).
    var startWith: PhotoSource?
    let onFinish: (EditorResult) -> Void

    @State private var draft: FillDraft
    /// Values the form started from (parser output for scans), plus anything filled from added photos —
    /// used to tell OCR values from the user's own edits.
    @State private var baseline: FillDraft
    @State private var annotations: FieldAnnotations?
    @State private var issues: [FieldKey: String] = [:]
    @State private var duplicate: Fill?
    @State private var editConflict: Fill?
    @State private var errorMessage: String?

    // Extra photos
    @State private var ocr: OCRPayload?
    @State private var stackedImage: UIImage?
    @State private var stackedLines: [OCRLine]
    @State private var addedPhoto = false
    @State private var ocrFilledKeys: Set<FieldKey> = []
    @State private var showingCamera = false
    @State private var showingPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isReadingPhoto = false
    @State private var photoMessage: String?
    @State private var didAutoStart = false

    init(title: String,
         initialDraft: FillDraft,
         baseline: FillDraft? = nil,
         purpose: EditorPurpose,
         annotations: FieldAnnotations? = nil,
         progressText: String? = nil,
         cancelTitle: String = "Cancel",
         startWith: PhotoSource? = nil,
         onFinish: @escaping (EditorResult) -> Void) {
        self.title = title
        self.purpose = purpose
        self.progressText = progressText
        self.cancelTitle = cancelTitle
        self.startWith = startWith
        self.onFinish = onFinish
        _draft = State(initialValue: initialDraft)
        _baseline = State(initialValue: baseline ?? initialDraft)
        _annotations = State(initialValue: annotations)

        switch purpose {
        case .create(_, let payload):
            _ocr = State(initialValue: payload)
            _stackedImage = State(initialValue: payload?.imageData.flatMap(UIImage.init(data:)))
            _stackedLines = State(initialValue: payload?.lines ?? [])
        case .update(let fill), .reparse(let fill, _):
            _stackedImage = State(initialValue: fill.imageData.flatMap(UIImage.init(data:)))
            _stackedLines = State(initialValue: fill.ocrLines)
        }
    }

    private var isScanSource: Bool {
        switch purpose {
        case .create(let source, _): source == .scan
        case .update(let f), .reparse(let f, _): f.source == .scan
        }
    }

    private var canAddPhoto: Bool {
        if case .reparse = purpose { return false }
        return true
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
                        .disabled(draft.text(.drugName) == nil || isReadingPhoto)
                }
            }
            .overlay {
                if isReadingPhoto {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.large)
                            Text("Reading photo…").font(.headline)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .onChange(of: draft) { _, newDraft in
                // Clear issues as soon as the user fixes them.
                guard !issues.isEmpty else { return }
                let current = newDraft.validationIssues()
                issues = issues.filter { current[$0.key] != nil }
            }
            .task {
                guard let startWith, !didAutoStart else { return }
                didAutoStart = true
                try? await Task.sleep(for: .milliseconds(350))
                switch startWith {
                case .camera where VNDocumentCameraViewController.isSupported: showingCamera = true
                default: showingPicker = true
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                DocumentCameraView { images in
                    showingCamera = false
                    addPhotos(images)
                } onCancel: {
                    showingCamera = false
                }
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showingPicker, selection: $pickerItems, maxSelectionCount: 4, matching: .images)
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task {
                    var images: [UIImage] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                            images.append(image)
                        }
                    }
                    addPhotos(images)
                }
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
        if canAddPhoto {
            Menu {
                Button {
                    showingCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(!VNDocumentCameraViewController.isSupported)
                Button {
                    showingPicker = true
                } label: {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
            } label: {
                Label("Add Photo for Missing Fields", systemImage: "plus.viewfinder")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(isReadingPhoto)
            .accessibilityHint("Reads another photo of this label and fills in only the fields that are still blank")
            if let photoMessage {
                Label(photoMessage, systemImage: "text.viewfinder")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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

    // MARK: - Extra photos

    /// OCRs each photo, fills only blank fields, and stacks the photo onto the stored image.
    private func addPhotos(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        isReadingPhoto = true
        Task {
            let service = OCRService()
            var filledAll: [FieldKey] = []
            var failures = 0
            for image in images {
                do {
                    let result = try await service.supplement(existingImage: stackedImage, existingLines: stackedLines, with: image)
                    stackedImage = result.image
                    stackedLines = result.lines
                    ocr = result.ocrPayload
                    addedPhoto = true

                    var updated = draft
                    let filled = updated.fillBlanks(from: result.parse)
                    draft = updated
                    var notes = annotations ?? FieldAnnotations()
                    for key in filled {
                        baseline[key] = draft[key]   // came from OCR, not a manual edit
                        notes.confidence[key] = result.parse.fields[key]?.confidence
                        notes.crops[key] = result.crops[key]
                    }
                    annotations = notes
                    ocrFilledKeys.formUnion(filled)
                    filledAll += filled
                } catch {
                    failures += 1
                }
            }
            isReadingPhoto = false
            var message: String
            if filledAll.isEmpty {
                message = failures == images.count
                    ? "The photo couldn't be read. Try a closer, well-lit shot."
                    : "No missing fields were found in the new photo."
            } else {
                let names = filledAll.prefix(8).map(\.label).joined(separator: ", ")
                let more = filledAll.count > 8 ? " and \(filledAll.count - 8) more" : ""
                message = "Filled \(filledAll.count) missing field\(filledAll.count == 1 ? "" : "s"): \(names)\(more). Check them below."
            }
            if failures > 0, failures < images.count {
                message += " \(failures) photo\(failures == 1 ? "" : "s") couldn't be read."
            }
            photoMessage = message
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
            case .create(let source, _):
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
                try repo.update(fill, with: draft, ocr: addedPhoto ? ocr : nil, ocrFilledKeys: ocrFilledKeys)
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
        guard case .create(let source, _) = purpose else { return }
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

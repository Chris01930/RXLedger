import SwiftData
import SwiftUI
import UIKit

struct FillDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let fill: Fill

    @State private var editing = false
    @State private var reparse: ReparseSession?
    @State private var showingPhoto = false
    @State private var confirmingDelete = false

    struct ReparseSession: Identifiable {
        let id = UUID()
        let result: ParseResult
        let annotations: FieldAnnotations
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LabelReconstructionView(fill: fill)

                recordInfo

                actions

                if let raw = fill.rawOCRText, !raw.isEmpty, fill.source == .scan {
                    DisclosureGroup("Raw OCR text") {
                        Text(raw)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .padding()
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(fill.displayName.isEmpty ? "Fill" : fill.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                FillEditorView(title: "Edit Fill", initialDraft: fill.draft(), purpose: .update(fill)) { result in
                    editing = false
                    if case .viewExisting(let other) = result { appState.open(other) }
                }
            }
        }
        .sheet(item: $reparse) { session in
            NavigationStack {
                FillEditorView(title: "Re-run Parser",
                               initialDraft: session.result.draft,
                               baseline: session.result.draft,
                               purpose: .reparse(fill, confidence: session.result.meanConfidence),
                               annotations: session.annotations) { result in
                    reparse = nil
                    if case .viewExisting(let other) = result { appState.open(other) }
                }
            }
        }
        .sheet(isPresented: $showingPhoto) {
            if let data = fill.imageData, let image = UIImage(data: data) {
                PhotoViewer(image: image, title: "Original Photo")
            }
        }
        .confirmationDialog("Delete this fill?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Fill", role: .destructive) {
                // Leave the screen first so nothing renders a deleted model.
                let repo = FillRepository(context: context)
                let target = fill
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    try? repo.delete(target)
                }
            }
        } message: {
            Text("\(DedupeService.describe(fill)) will be permanently removed.")
        }
    }

    private var recordInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SourceBadge(source: fill.source, edited: fill.wasEditedAfterScan)
                if let c = fill.ocrConfidence, fill.source == .scan {
                    ConfidenceBadge(confidence: c)
                }
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Recorded").foregroundStyle(.secondary)
                    Text(fill.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                GridRow {
                    Text("Last updated").foregroundStyle(.secondary)
                    Text(fill.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if fill.source == .scan {
                    GridRow {
                        Text("Edited after scan").foregroundStyle(.secondary)
                        Text(fill.wasEditedAfterScan ? "Yes" : "No")
                    }
                }
                if let due = fill.nextRefillEstimate {
                    GridRow {
                        Text("Refill due ~").foregroundStyle(.secondary)
                        Text(LabelFormat.formatMedium(due))
                    }
                }
                GridRow {
                    Text("Duplicate key").foregroundStyle(.secondary)
                    Text(DedupeService.isUnkeyed(fill.dedupeKey) ? "None (no Rx or NDC + date)" : fill.dedupeKey)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var canReparse: Bool {
        !(fill.rawOCRText ?? "").isEmpty || !fill.ocrLines.isEmpty
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if fill.imageData != nil {
                Button {
                    showingPhoto = true
                } label: {
                    Label("View Original Photo", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                editing = true
            } label: {
                Label("Edit", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if canReparse {
                Button(action: startReparse) {
                    Label("Re-run Parser on Stored OCR Text", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete Fill", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private func startReparse() {
        let lines = fill.ocrLines.isEmpty ? OCRLine.fromPlainText(fill.rawOCRText ?? "") : fill.ocrLines
        let result = CVSLabelParser().parse(pagedLines: lines)
        var annotations = FieldAnnotations(confidence: result.confidences)
        if let data = fill.imageData, let cg = UIImage(data: data)?.cgImage {
            for key in result.fields.keys {
                if let box = result.boundingBox(for: key), let crop = ImageProcessing.crop(cg, normalizedRect: box) {
                    annotations.crops[key] = crop
                }
            }
        }
        reparse = ReparseSession(result: result, annotations: annotations)
    }
}

#Preview {
    NavigationStack {
        FillDetailView(fill: SampleData.previewFill())
    }
    .environment(AppState())
    .modelContainer(PersistenceController.preview)
}

import SwiftUI

/// Steps through each scanned page's review form. Saved pages are committed one at a time.
struct ScanReviewQueue: View {
    let results: [ScanResult]
    /// Called once at the end with the last saved fill (or a request to view an existing one).
    let onDone: (EditorResult) -> Void

    @State private var index = 0
    @State private var lastSaved: Fill?
    @State private var showingPhoto = false

    var body: some View {
        let result = results[index]
        let isLast = index == results.count - 1
        NavigationStack {
            FillEditorView(title: "Review Scan",
                           initialDraft: result.parse.draft,
                           baseline: result.parse.draft,
                           purpose: .create(source: .scan, ocr: result.ocrPayload),
                           annotations: result.annotations,
                           progressText: results.count > 1 ? "Label \(index + 1) of \(results.count)" : nil,
                           cancelTitle: isLast ? "Cancel" : "Skip") { outcome in
                switch outcome {
                case .saved(let fill):
                    lastSaved = fill
                    advance()
                case .cancelled:
                    advance()
                case .viewExisting(let fill):
                    onDone(.viewExisting(fill))
                }
            }
            .id(result.id)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showingPhoto = true
                    } label: {
                        Label("View Photo", systemImage: "photo")
                    }
                }
                ToolbarItem(placement: .status) {
                    if let c = result.parse.meanConfidence {
                        ConfidenceBadge(confidence: c)
                    }
                }
            }
            .sheet(isPresented: $showingPhoto) {
                PhotoViewer(image: result.image, title: "Scanned Label")
            }
        }
        .interactiveDismissDisabled()
    }

    private func advance() {
        if index < results.count - 1 {
            index += 1
        } else {
            onDone(lastSaved.map { .saved($0) } ?? .cancelled)
        }
    }
}

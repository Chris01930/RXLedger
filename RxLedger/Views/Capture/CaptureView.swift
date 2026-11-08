import PhotosUI
import SwiftUI
import VisionKit

/// Capture tab: scan with the document camera or pick photos, run OCR, then review each page.
struct CaptureView: View {
    @Environment(AppState.self) private var appState
    @State private var model = CaptureModel()
    @State private var showingCamera = false
    @State private var showingManualEntry = false
    @State private var photoItems: [PhotosPickerItem] = []

    private var cameraAvailable: Bool { VNDocumentCameraViewController.isSupported }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(.top, 24)
                        .accessibilityHidden(true)
                    Text("Scan a CVS label")
                        .font(.title2.bold())
                    Text("Fit the whole label in the frame. You can capture several labels in one session — each page is read separately and you'll review every one before it's saved.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Button {
                        showingCamera = true
                    } label: {
                        Label("Scan Label", systemImage: "camera.viewfinder")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!cameraAvailable || model.isProcessing)
                    .accessibilityHint("Opens the document camera")

                    if !cameraAvailable {
                        Text("The camera isn't available on this device. Choose a photo instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isProcessing)
                    .accessibilityHint("Pick one or more label photos from your library")

                    Button {
                        showingManualEntry = true
                    } label: {
                        Label("Add Manually", systemImage: "square.and.pencil")
                    }
                    .padding(.top, 4)

                    Label("Text recognition runs entirely on this iPhone. Nothing is uploaded.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Capture")
            .overlay {
                if model.isProcessing {
                    ProcessingOverlay(text: model.progressText)
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                DocumentCameraView { images in
                    showingCamera = false
                    model.process(images)
                } onCancel: {
                    showingCamera = false
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: Binding(get: { !model.results.isEmpty }, set: { if !$0 { model.results = [] } })) {
                ScanReviewQueue(results: model.results) { outcome in
                    model.results = []
                    switch outcome {
                    case .saved(let fill): appState.showSaved(fill)
                    case .viewExisting(let fill): appState.open(fill)
                    case .cancelled: break
                    }
                }
            }
            .sheet(isPresented: $showingManualEntry) {
                NavigationStack {
                    FillEditorView(title: "Add Manually", initialDraft: FillDraft(), purpose: .create(source: .manual, ocr: nil)) { result in
                        showingManualEntry = false
                        switch result {
                        case .saved(let fill): appState.showSaved(fill)
                        case .viewExisting(let fill): appState.open(fill)
                        case .cancelled: break
                        }
                    }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                model.process(items)
            }
            .alert("Some labels couldn't be read",
                   isPresented: Binding(get: { !model.failures.isEmpty && model.results.isEmpty && !model.isProcessing },
                                        set: { if !$0 { model.failures = [] } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.failures.joined(separator: "\n"))
            }
            #if DEBUG
            .task { model.processDebugLaunchImage() }
            #endif
        }
    }
}

/// Runs OCR on captured images and holds the results for review.
@MainActor
@Observable
final class CaptureModel {
    var isProcessing = false
    var progressText = ""
    var results: [ScanResult] = []
    var failures: [String] = []

    private let ocr = OCRService()

    func process(_ images: [UIImage]) {
        run(count: images.count) { index in images[index] }
    }

    func process(_ items: [PhotosPickerItem]) {
        run(count: items.count) { index in
            guard let data = try await items[index].loadTransferable(type: Data.self) else { return nil }
            return UIImage(data: data)
        }
    }

    private func run(count: Int, image: @escaping (Int) async throws -> UIImage?) {
        guard count > 0 else { return }
        isProcessing = true
        failures = []
        Task {
            var collected: [ScanResult] = []
            for index in 0..<count {
                progressText = count > 1 ? "Reading label \(index + 1) of \(count)…" : "Reading label…"
                do {
                    guard let img = try await image(index) else { throw OCRError.unreadableImage }
                    collected.append(try await ocr.process(img))
                } catch {
                    failures.append("Page \(index + 1): \(error.localizedDescription)")
                }
            }
            isProcessing = false
            results = collected
        }
    }

    #if DEBUG
    /// `-scanImagePath /path/to/label.jpg` runs the full OCR pipeline at launch (simulator testing).
    func processDebugLaunchImage() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-scanImagePath"), i + 1 < args.count,
              let image = UIImage(contentsOfFile: args[i + 1]), results.isEmpty, !isProcessing else { return }
        process([image])
    }
    #endif
}

private struct ProcessingOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(text).font(.headline)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// VisionKit document camera (perspective-corrected, multi-page).
struct DocumentCameraView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCameraView
        init(_ parent: DocumentCameraView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}

#Preview {
    CaptureView()
        .environment(AppState())
        .modelContainer(PersistenceController.preview)
}

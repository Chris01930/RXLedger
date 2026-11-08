import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppLockManager.self) private var lock
    @Environment(AppState.self) private var appState
    @Query private var fills: [Fill]
    @Query private var medications: [Medication]

    @State private var exportDocument: ExportDocument?
    @State private var exportName = ""
    @State private var showingImporter = false
    @State private var confirmingDeleteAll = false
    @State private var alert: AlertMessage?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { lock.isEnabled },
                                         set: { value in Task { await lock.setEnabled(value) } })) {
                        Label("Require \(lock.biometryName)", systemImage: "faceid")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Locks RxLedger whenever it goes to the background, and hides its contents in the app switcher.")
                }

                Section {
                    LabeledContent("Fills", value: "\(fills.count)")
                    LabeledContent("Medications", value: "\(medications.count)")
                    Button {
                        export(csv: true)
                    } label: {
                        Label("Export Fills as CSV", systemImage: "tablecells")
                    }
                    .disabled(fills.isEmpty)
                    Button {
                        export(csv: false)
                    } label: {
                        Label("Export JSON Backup", systemImage: "externaldrive")
                    }
                    .disabled(fills.isEmpty)
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import JSON Backup", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("The JSON backup includes every field, the OCR text and the label photos. Importing skips fills you already have.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingDeleteAll = true
                    } label: {
                        Label("Delete All Data", systemImage: "trash")
                    }
                    .disabled(fills.isEmpty && medications.isEmpty)
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.versionString)
                    Label("All data stays on this device. RxLedger makes no network connections.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                          document: exportDocument,
                          contentType: exportDocument?.contentType ?? .json,
                          defaultFilename: exportName) { result in
                if case .failure(let error) = result {
                    alert = AlertMessage(title: "Export failed", message: error.localizedDescription)
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                importBackup(result)
            }
            .confirmationDialog("Delete all data?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive, action: deleteAll)
            } message: {
                Text("This permanently removes all \(fills.count) fills, medications, pharmacies, prescribers, plans and photos from this device. Export a backup first if you might need them.")
            }
            .alert(item: $alert) { a in
                Alert(title: Text(a.title), message: Text(a.message))
            }
            .onChange(of: lock.lastError) { _, error in
                if let error, !lock.isLocked {
                    alert = AlertMessage(title: "App lock", message: error)
                }
            }
        }
    }

    private func export(csv: Bool) {
        do {
            if csv {
                exportName = ExportService.timestampedName("RxLedger-fills") + ".csv"
                exportDocument = ExportDocument(data: Data(ExportService.csv(for: fills).utf8), contentType: .commaSeparatedText)
            } else {
                exportName = ExportService.timestampedName("RxLedger-backup") + ".json"
                exportDocument = ExportDocument(data: try ExportService.backupData(context: context), contentType: .json)
            }
        } catch {
            alert = AlertMessage(title: "Export failed", message: error.localizedDescription)
        }
    }

    private func importBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let summary = try ExportService.importBackup(data, context: context)
            alert = AlertMessage(title: "Import complete", message: summary.message)
        } catch {
            alert = AlertMessage(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func deleteAll() {
        do {
            appState.fillsPath = []
            try PersistenceController.deleteAllData(in: context)
        } catch {
            alert = AlertMessage(title: "Couldn't delete", message: error.localizedDescription)
        }
    }
}

extension Bundle {
    var versionString: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .environment(AppLockManager(previewUnlocked: true))
        .modelContainer(PersistenceController.preview)
}

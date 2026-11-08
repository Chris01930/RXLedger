import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLockManager.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.selectedTab) {
            FillsListView()
                .tabItem { Label("Fills", systemImage: "list.bullet.rectangle") }
                .tag(AppState.Tab.fills)
            MedicationsListView()
                .tabItem { Label("Medications", systemImage: "pills") }
                .tag(AppState.Tab.medications)
            CaptureView()
                .tabItem { Label("Capture", systemImage: "doc.viewfinder") }
                .tag(AppState.Tab.capture)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppState.Tab.settings)
        }
        .overlay {
            if lock.shouldObscureContent(scenePhase: scenePhase) {
                LockScreenView()
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            lock.handle(scenePhase: phase)
        }
        #if DEBUG
        .sheet(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("-previewConflictSheet"))) {
            ConflictReviewSheet(conflicts: [
                FieldConflict(key: .tp, currentValue: "93125", currentSource: .scan(confidence: 0.3), newValue: "33125", newConfidence: 1.0),
                FieldConflict(key: .daysSupply, currentValue: "2", currentSource: .scan(confidence: 0.5), newValue: "28", newConfidence: 1.0),
                FieldConflict(key: .amountDue, currentValue: "8.67", currentSource: .edited, newValue: "8.57", newConfidence: 0.5),
            ]) { _ in }
        }
        #endif
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .environment(AppLockManager(previewUnlocked: true))
        .modelContainer(PersistenceController.preview)
}

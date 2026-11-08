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
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .environment(AppLockManager(previewUnlocked: true))
        .modelContainer(PersistenceController.preview)
}

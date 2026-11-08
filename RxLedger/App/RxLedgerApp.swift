import SwiftData
import SwiftUI

@main
struct RxLedgerApp: App {
    @State private var appState = AppState()
    @State private var lock = AppLockManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(lock)
        }
        .modelContainer(PersistenceController.shared)
    }
}

/// App-wide navigation state.
@Observable
final class AppState {
    enum Tab: Hashable {
        case fills, medications, capture, settings
    }

    var selectedTab: Tab = .fills
    /// Navigation stack of the Fills tab.
    var fillsPath: [Fill] = []
    /// A fill row to flash briefly (e.g. right after saving).
    var highlightedFillID: UUID?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-scanImagePath") { selectedTab = .capture }
        #endif
    }

    /// Switch to the Fills tab and highlight a fill.
    func showSaved(_ fill: Fill) {
        fillsPath = []
        selectedTab = .fills
        highlightedFillID = fill.id
    }

    /// Switch to the Fills tab and open a fill's detail.
    func open(_ fill: Fill) {
        selectedTab = .fills
        fillsPath = [fill]
        highlightedFillID = fill.id
    }
}

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Settings coming soon", systemImage: "gearshape")
                .navigationTitle("Settings")
        }
    }
}

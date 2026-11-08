import SwiftUI

struct CaptureView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Scanning coming soon", systemImage: "doc.viewfinder")
                .navigationTitle("Capture")
        }
    }
}

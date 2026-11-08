import SwiftUI
import UIKit

/// Full-screen, pinch-to-zoom image viewer.
struct PhotoViewer: View {
    let image: UIImage
    var title: String = "Photo"
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 6) }
                        .onEnded { _ in lastScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = scale > 1 ? 1 : 2.5 }
                    lastScale = scale
                }
            }
            .background(Color.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Photo of the label. Pinch or double-tap to zoom.")
        }
    }
}

#Preview {
    PhotoViewer(image: UIImage(systemName: "doc.text.image")!)
}

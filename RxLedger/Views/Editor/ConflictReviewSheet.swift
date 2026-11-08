import SwiftUI
import UIKit

/// Shown after an added photo reads some fields differently: for each one, pick the current value or
/// the new reading, comparing their sources, confidences and label crops.
struct ConflictReviewSheet: View {
    let conflicts: [FieldConflict]
    /// Called with the keys whose new value should be used.
    let onApply: (Set<FieldKey>) -> Void

    @State private var useNew: Set<FieldKey>
    @State private var zoom: ZoomItem?

    private struct ZoomItem: Identifiable {
        let id = UUID()
        let image: UIImage
        let title: String
    }

    init(conflicts: [FieldConflict], onApply: @escaping (Set<FieldKey>) -> Void) {
        self.conflicts = conflicts
        self.onApply = onApply
        _useNew = State(initialValue: Set(conflicts.filter(\.prefersNew).map(\.key)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("The new photo read \(conflicts.count) field\(conflicts.count == 1 ? "" : "s") differently. Tap the value to keep for each. Values you typed are kept unless you choose otherwise.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("Keep All Current") { useNew = [] }
                        Button("Use All New") { useNew = Set(conflicts.map(\.key)) }
                        Button("Use Higher Confidence") { useNew = Set(conflicts.filter(\.prefersNew).map(\.key)) }
                    } label: {
                        Label("Select…", systemImage: "checklist")
                    }
                }
                ForEach(conflicts) { c in
                    Section(c.key.label) {
                        if let image = c.newContext ?? c.newCrop {
                            Button {
                                zoom = ZoomItem(image: image, title: c.key.label)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("In the new photo — outlined is what was read")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: .infinity, maxHeight: 130)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
                                        .overlay(alignment: .bottomTrailing) {
                                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                .font(.caption.weight(.bold))
                                                .padding(6)
                                                .background(.ultraThinMaterial, in: Circle())
                                                .padding(6)
                                        }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Photo of \(c.key.label) in the new scan")
                            .accessibilityHint("Opens it full screen to zoom")
                        }
                        option(selected: !useNew.contains(c.key),
                               title: "Current",
                               value: c.currentValue,
                               detail: c.currentSource.description,
                               confidence: { if case .scan(let v) = c.currentSource { return v } else { return nil } }(),
                               crop: c.currentCrop) {
                            useNew.remove(c.key)
                        }
                        option(selected: useNew.contains(c.key),
                               title: "New photo",
                               value: c.newValue,
                               detail: "New photo · \(Int((c.newConfidence * 100).rounded()))%",
                               confidence: c.newConfidence,
                               crop: nil) {
                            useNew.insert(c.key)
                        }
                    }
                }
            }
            .navigationTitle("Review Differences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep Current") { onApply([]) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(useNew) }
                        .fontWeight(.semibold)
                }
            }
        }
        .interactiveDismissDisabled()
        .sheet(item: $zoom) { item in
            PhotoViewer(image: item.image, title: item.title)
        }
    }

    private func option(selected: Bool, title: String, value: String, detail: String,
                        confidence: Double?, crop: UIImage?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(value)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let confidence {
                            Circle().fill(ConfidenceLevel(confidence).color).frame(width: 7, height: 7)
                        }
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let crop {
                        Image(uiImage: crop)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 44, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))
                            .accessibilityLabel("Image of the label text for this reading")
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }
}

#Preview {
    ConflictReviewSheet(conflicts: [
        FieldConflict(key: .tp, currentValue: "93125", currentSource: .scan(confidence: 0.3), newValue: "33125", newConfidence: 1.0),
        FieldConflict(key: .amountDue, currentValue: "8.67", currentSource: .edited, newValue: "8.57", newConfidence: 0.5),
        FieldConflict(key: .patientName, currentValue: "Sample, Alex", currentSource: .entered, newValue: "Sample, Alex J", newConfidence: 1.0),
    ]) { _ in }
}

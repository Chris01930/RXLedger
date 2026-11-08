import SwiftData
import SwiftUI

struct FillDetailView: View {
    @Environment(AppState.self) private var appState
    let fill: Fill
    @State private var editing = false

    var body: some View {
        List {
            Section {
                ForEach(FieldKey.allCases) { key in
                    let v = fill.stringValue(for: key)
                    if !v.isEmpty { LabeledContent(key.label, value: v) }
                }
            }
            Section { SourceBadge(source: fill.source, edited: fill.wasEditedAfterScan) }
        }
        .navigationTitle(fill.displayName)
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) {
            NavigationStack {
                FillEditorView(title: "Edit Fill", initialDraft: fill.draft(), purpose: .update(fill)) { result in
                    editing = false
                    if case .viewExisting(let other) = result { appState.open(other) }
                }
            }
        }
    }
}

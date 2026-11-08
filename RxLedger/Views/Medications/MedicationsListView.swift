import SwiftData
import SwiftUI

struct MedicationsListView: View {
    @Query(sort: \Medication.displayName) private var medications: [Medication]
    @AppStorage("medications.hideInactive") private var hideInactive = true

    private var visible: [Medication] {
        medications
            .filter { !hideInactive || $0.isActive }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visible) { med in
                    NavigationLink(value: med) {
                        MedicationRow(medication: med)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Medications")
            .navigationDestination(for: Medication.self) { MedicationDetailView(medication: $0) }
            .navigationDestination(for: Fill.self) { FillDetailView(fill: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $hideInactive) {
                        Label("Hide inactive", systemImage: hideInactive ? "eye.slash" : "eye")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel(hideInactive ? "Showing active only. Show inactive medications" : "Showing all. Hide inactive medications")
                }
            }
            .overlay {
                if medications.isEmpty {
                    ContentUnavailableView("No Medications", systemImage: "pills",
                                           description: Text("Medications appear here once you record a fill."))
                } else if visible.isEmpty {
                    ContentUnavailableView("All Medications Inactive", systemImage: "eye.slash",
                                           description: Text("Tap the eye button to show inactive medications."))
                }
            }
        }
    }
}

struct MedicationRow: View {
    let medication: Medication

    var body: some View {
        let last = medication.lastFill
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(medication.drugName).font(.headline)
                if !medication.isActive {
                    Text("Inactive")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
            }
            if let sf = medication.strengthForm {
                Text(sf).font(.subheadline).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("Last fill").foregroundStyle(.secondary)
                    Text(LabelFormat.formatMedium(last?.dateFilled))
                    Text("Copay").foregroundStyle(.secondary)
                    Text(LabelFormat.formatMoney(last?.amountDue))
                }
                GridRow {
                    Text("Qty / days").foregroundStyle(.secondary)
                    Text([last?.quantityText, last?.daysSupply.map { "\($0) d" }].compactMap { $0 }.joined(separator: " / ").nilIfEmpty ?? "—")
                    Text("Refills").foregroundStyle(.secondary)
                    Text(last?.refillsRemaining.map(String.init) ?? "—")
                }
            }
            .font(.caption)
            .monospacedDigit()
            if let due = medication.nextRefillEstimate {
                Label("Refill due ~\(LabelFormat.formatMedium(due))", systemImage: "calendar.badge.clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(due < Date() ? .orange : .accentColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview {
    MedicationsListView()
        .environment(AppState())
        .modelContainer(PersistenceController.preview)
}

import SwiftData
import SwiftUI

struct MedicationDetailView: View {
    @Bindable var medication: Medication

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(medication.drugName).font(.title2.bold())
                    if let sf = medication.strengthForm { Text(sf).foregroundStyle(.secondary) }
                    if let brands = medication.commonBrands { Text("Brands: \(brands)").font(.subheadline) }
                    if let ndc = medication.ndc { Text("NDC \(ndc)").font(.subheadline).monospacedDigit() }
                    if let mfr = medication.manufacturer { Text("Mfr: \(mfr)").font(.subheadline) }
                }
                .padding(.vertical, 4)
                Toggle("Active medication", isOn: $medication.isActive)
            }

            Section("Totals") {
                LabeledContent("Number of fills", value: "\(medication.fillCount)")
                LabeledContent("Copay paid", value: LabelFormat.formatMoney(medication.totalCopayPaid))
                LabeledContent("Retail value", value: LabelFormat.formatMoney(medication.totalRetail))
                LabeledContent("Last filled", value: LabelFormat.formatMedium(medication.lastFill?.dateFilled))
                LabeledContent("Estimated refill due", value: LabelFormat.formatMedium(medication.nextRefillEstimate))
                if let refills = medication.lastFill?.refillsRemaining {
                    LabeledContent("Refills remaining", value: "\(refills)")
                }
            }
            .monospacedDigit()

            Section("Fill History") {
                ForEach(medication.sortedFills) { fill in
                    NavigationLink(value: fill) {
                        FillRow(fill: fill)
                    }
                }
            }
        }
        .navigationTitle(medication.drugName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        MedicationDetailView(medication: SampleData.previewMedication())
    }
    .environment(AppState())
    .modelContainer(PersistenceController.preview)
}

import CoreImage.CIFilterBuiltins
import SwiftUI

/// A SwiftUI re-creation of the CVS bag-tag label, drawn from stored data (not the photo).
/// Same section order and headers as the printed label; text uses Dynamic Type and wraps freely.
struct LabelReconstructionView: View {
    let fill: Fill
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let ink = Color.black
    private let paper = Color.white
    private let band = Color(white: 0.86)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            patientBand
            sectionBar("Prescription Information")
            prescriptionInfo
            if !fill.importantInfo.isEmpty {
                importantInfo
            }
            sectionBar("Receipt & Refill Information")
            receipt
            sectionBar("Notes from the Pharmacy")
            Text(fill.pharmacyNotes ?? " ")
                .font(.footnote)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .padding(10)
            if hasSticker {
                sticker
                    .padding(10)
            }
        }
        .foregroundStyle(ink)
        .background(paper)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.25)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reconstructed pharmacy label")
    }

    private var stacked: Bool { dynamicTypeSize.isAccessibilitySize }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text([fill.storeCode, fill.binSlot].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "—")
                    .font(.largeTitle.weight(.black))
                    .accessibilityLabel("Store code and bin \(fill.storeCode ?? "") \(fill.binSlot ?? "")")
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    if let promised = fill.promisedAt {
                        Text("Promised: \(LabelFormat.formatDateTime(promised))")
                    }
                    if let scripts = fill.scriptsCount {
                        Text("# Scripts: \(String(format: "%02d", scripts))")
                    }
                    if fill.readyFill {
                        Text("ReadyFill")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(ink, lineWidth: 1.5))
                    }
                }
                .font(.caption.weight(.semibold))
            }
            if let barcode = fill.barcode {
                VStack(spacing: 2) {
                    if let image = Self.barcodeImage(barcode) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(height: 44)
                            .accessibilityHidden(true)
                    }
                    Text(barcode)
                        .font(.caption.monospacedDigit())
                        .accessibilityLabel("Barcode \(barcode)")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
    }

    static func barcodeImage(_ digits: String) -> UIImage? {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(digits.utf8)
        filter.quietSpace = 0
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Patient band

    private var patientBand: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fill.patientName ?? "—").font(.headline)
            if let street = fill.patientStreet { Text(street) }
            if let csz = cityStateZip(fill.patientCity, fill.patientState, fill.patientZip) { Text(csz) }
            HStack(spacing: 16) {
                if let dob = fill.patientDOB { Text("DOB: \(dob)") }
                if let tel = fill.patientPhone { Text("TEL: \(tel)") }
            }
            .font(.footnote.weight(.semibold))
            .padding(.top, 2)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(band)
    }

    // MARK: Prescription information

    private func sectionBar(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.black)
            .accessibilityAddTraits(.isHeader)
    }

    private var prescriptionInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(fill.drugName.isEmpty ? "—" : fill.drugName).font(.title3.weight(.heavy))
                if let sf = fill.strengthForm { Text(sf).font(.title3.weight(.heavy)) }
            }
            if let brands = fill.commonBrands {
                Text("Common brand(s): \(brands)").font(.footnote)
            }
            if let directions = fill.directions {
                Text(directions).font(.body.weight(.semibold))
            }
            scheduleBoxes
        }
        .padding(12)
    }

    private struct ScheduleSlot {
        let title: String
        let value: String?
        let color: Color
        let textColor: Color
    }

    private var scheduleSlots: [ScheduleSlot] {
        [
            ScheduleSlot(title: "Morning", value: fill.scheduleMorning, color: Color(red: 0.95, green: 0.74, blue: 0.13), textColor: .black),
            ScheduleSlot(title: "Midday", value: fill.scheduleMidday, color: Color(red: 0.96, green: 0.50, blue: 0.13), textColor: .black),
            ScheduleSlot(title: "Evening", value: fill.scheduleEvening, color: Color(red: 0.20, green: 0.48, blue: 0.85), textColor: .white),
            ScheduleSlot(title: "Bedtime", value: fill.scheduleBedtime, color: Color(red: 0.08, green: 0.15, blue: 0.38), textColor: .white),
        ]
    }

    private var seeDirections: Bool {
        scheduleSlots.compactMap(\.value).contains { $0.uppercased().contains("SEE DIRECTIONS") }
    }

    @ViewBuilder
    private var scheduleBoxes: some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        VStack(spacing: 0) {
            layout {
                ForEach(scheduleSlots, id: \.title) { slot in
                    VStack(spacing: 0) {
                        Text(slot.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(slot.textColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(slot.color)
                        if !seeDirections {
                            Text(slot.value ?? " ")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                    }
                    .overlay(Rectangle().stroke(slot.color, lineWidth: 2))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(slot.title): \(seeDirections ? "see directions" : (slot.value ?? "none"))")
                }
            }
            if seeDirections {
                Text("SEE DIRECTIONS")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 4)
    }

    private var importantInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Important Information")
                .font(.subheadline.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(fill.importantInfo.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(item)
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: Receipt & refill

    private var receipt: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                             : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                if let name = fill.pharmacyName { Text(name).fontWeight(.bold) }
                if let street = fill.pharmacyStreet { Text(street) }
                if let csz = cityStateZip(fill.pharmacyCity, fill.pharmacyState, fill.pharmacyZip) { Text(csz) }
                field("STORE#", fill.storeNumber)
                field("STORE TEL", fill.storePhone)
                rxLine
                Text("INSURANCE INFORMATION:").fontWeight(.bold).padding(.top, 4)
                if let plan = fill.insurancePlanName { Text(plan) }
                if let bin = fill.bin { Text("BIN \(bin)") }
                field("TP", fill.tp)
                field("GR", fill.gr)
                field("AUTH#", fill.authNumber)
                field("RETAIL PRICE", fill.retailPrice.map { LabelFormat.formatMoney($0) })
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                field("NDC", fill.ndc)
                field("DAW", fill.daw.map(String.init))
                field("QTY", fill.quantityText)
                field("CAP", fill.capType)
                field("MFR PKG", fill.mfrPackage)
                field("REFILL", fill.refillsRemaining.map { $0 == 0 ? "No Refills" : "\($0) Refill\($0 == 1 ? "" : "s")" })
                field("MFR", fill.manufacturer)
                field("PRSCBR", fill.prescriberName)
                field("DAYS SUPPLY", fill.daysSupply.map(String.init))
                field("DATE FILLED", fill.dateFilled.map { LabelFormat.formatDate($0) })
                HStack(alignment: .firstTextBaseline) {
                    Text("AMOUNT DUE:")
                    Text(LabelFormat.formatMoney(fill.amountDue))
                }
                .font(.subheadline.weight(.heavy))
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(12)
    }

    private var rxLine: some View {
        HStack(spacing: 6) {
            Text("RX:").fontWeight(.bold)
            Text([fill.rxNumber, fill.fillNumber].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "—")
                .fontWeight(.bold)
            if fill.refillFlag {
                Text("RF")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 3)
                    .overlay(Rectangle().stroke(ink, lineWidth: 1.2))
                    .accessibilityLabel("Refill")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(label):").fontWeight(.semibold)
                Text(value)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func cityStateZip(_ city: String?, _ state: String?, _ zip: String?) -> String? {
        let stateZip = [state, zip].compactMap { $0 }.joined(separator: " ")
        let parts = [city, stateZip.nilIfEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Side sticker

    private var hasSticker: Bool {
        fill.drugStorageType != nil || fill.stickerDate != nil || fill.stickerTP != nil
    }

    private var sticker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Side sticker").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            field("DRUG STORAGE TYPE", fill.drugStorageType)
            field("DATE", fill.stickerDate.map { LabelFormat.formatDate($0) })
            field("TP", fill.stickerTP)
        }
        .font(.caption)
        .padding(8)
        .background(Color(red: 1, green: 0.96, blue: 0.75), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.2)))
    }
}

#Preview {
    ScrollView {
        LabelReconstructionView(fill: SampleData.previewFill())
            .padding()
    }
    .background(Color(.systemGroupedBackground))
    .modelContainer(PersistenceController.preview)
}

#Preview("Accessibility size") {
    ScrollView {
        LabelReconstructionView(fill: SampleData.previewFill())
            .padding()
    }
    .environment(\.dynamicTypeSize, .accessibility2)
    .modelContainer(PersistenceController.preview)
}

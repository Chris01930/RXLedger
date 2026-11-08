import SwiftData
import SwiftUI
import UIKit

/// The editable field list. Sections are ordered by how often fields are needed
/// (drug and refill details first); see DECISIONS.md.
struct FillFormView<Header: View>: View {
    @Binding var draft: FillDraft
    let baseline: FillDraft
    let annotations: FieldAnnotations?
    let issues: [FieldKey: String]
    @ViewBuilder var header: () -> Header

    @Query(sort: \Pharmacy.name) private var pharmacies: [Pharmacy]
    @Query(sort: \Prescriber.name) private var prescribers: [Prescriber]
    @Query(sort: \InsurancePlan.planName) private var plans: [InsurancePlan]
    @Query(sort: \Patient.name) private var patients: [Patient]

    static var sectionOrder: [LabelSection] {
        [.prescription, .refill, .insurance, .pharmacy, .patient, .header, .notes, .sticker]
    }

    private var isReview: Bool { annotations != nil }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section { header() }
                ForEach(Self.sectionOrder) { section in
                    Section {
                        if section == .refill {
                            prescriberPicker
                        }
                        ForEach(FieldKey.fields(in: section)) { key in
                            FieldRow(key: key,
                                     value: $draft[key],
                                     confidence: annotations?.confidence[key],
                                     crop: annotations?.crops[key],
                                     isEdited: isReview && draft.text(key) != baseline.text(key),
                                     issue: issues[key],
                                     highlightBlank: isReview && draft.text(key) == nil && key.kind != .bool)
                                .id(key)
                        }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            savedValuesMenu(for: section)
                        }
                    }
                }
            }
            .onChange(of: issues.keys.sorted { $0.rawValue < $1.rawValue }) { _, keys in
                let ordered = Self.sectionOrder.flatMap { FieldKey.fields(in: $0) }
                if let first = ordered.first(where: { keys.contains($0) }) {
                    withAnimation { proxy.scrollTo(first, anchor: .center) }
                }
            }
        }
    }

    // MARK: Pickers offering existing values

    @ViewBuilder
    private func savedValuesMenu(for section: LabelSection) -> some View {
        switch section {
        case .pharmacy where !pharmacies.isEmpty:
            Menu {
                ForEach(pharmacies) { p in
                    Button(p.summary) { apply(p) }
                }
            } label: { pickerLabel }
            .accessibilityLabel("Use a saved pharmacy")
        case .insurance where !plans.isEmpty:
            Menu {
                ForEach(plans) { plan in
                    Button(plan.summary) { apply(plan) }
                }
            } label: { pickerLabel }
            .accessibilityLabel("Use a saved insurance plan")
        case .patient where !patients.isEmpty:
            Menu {
                ForEach(patients) { p in
                    Button(p.name) { apply(p) }
                }
            } label: { pickerLabel }
            .accessibilityLabel("Use a saved patient")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var prescriberPicker: some View {
        if !prescribers.isEmpty {
            Menu {
                ForEach(prescribers) { p in
                    Button(p.name) { draft[.prescriberName] = p.name }
                }
            } label: {
                Label("Choose saved prescriber", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.subheadline)
            }
        }
    }

    private var pickerLabel: some View {
        Label("Saved", systemImage: "tray.full")
            .font(.caption.weight(.semibold))
            .textCase(nil)
    }

    private func apply(_ p: Pharmacy) {
        draft[.pharmacyName] = p.name ?? ""
        draft[.pharmacyStreet] = p.street ?? ""
        draft[.pharmacyCity] = p.city ?? ""
        draft[.pharmacyState] = p.state ?? ""
        draft[.pharmacyZip] = p.zip ?? ""
        draft[.storeNumber] = p.storeNumber ?? ""
        draft[.storePhone] = p.phone ?? ""
    }

    private func apply(_ plan: InsurancePlan) {
        draft[.insurancePlanName] = plan.planName ?? ""
        draft[.bin] = plan.bin ?? ""
        draft[.tp] = plan.tp ?? ""
        draft[.gr] = plan.gr ?? ""
    }

    private func apply(_ p: Patient) {
        draft[.patientName] = p.name
        draft[.patientStreet] = p.street ?? ""
        draft[.patientCity] = p.city ?? ""
        draft[.patientState] = p.state ?? ""
        draft[.patientZip] = p.zip ?? ""
        draft[.patientDOB] = p.dobMonthYear ?? ""
        draft[.patientPhone] = p.phone ?? ""
    }
}

/// One editable field with optional confidence tint, OCR crop, and validation message.
struct FieldRow: View {
    let key: FieldKey
    @Binding var value: String
    var confidence: Double?
    var crop: UIImage?
    var isEdited: Bool = false
    var issue: String?
    var highlightBlank: Bool = false

    private var tint: Color? {
        if issue != nil { return .red }
        if isEdited { return .blue }
        if highlightBlank { return .red }
        if let confidence { return ConfidenceLevel(confidence).color }
        return nil
    }

    var body: some View {
        content
            .listRowBackground(tint.map { $0.opacity(0.12) })
    }

    @ViewBuilder
    private var content: some View {
        switch key.kind {
        case .bool:
            Toggle(isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "" })) {
                labelLine
            }
        case .choice(let options):
            Picker(selection: $value) {
                Text("—").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
                if !value.isEmpty, !options.contains(value) {
                    Text(value).tag(value)
                }
            } label: {
                labelLine
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                labelLine
                HStack {
                    TextField(key.placeholder, text: $value, axis: isMultiline ? .vertical : .horizontal)
                        .lineLimit(isMultiline ? 2...8 : 1...1)
                        .keyboardType(keyboardType)
                        .textInputAutocapitalization(autocapitalization)
                        .autocorrectionDisabled(key.kind != .multiline)
                        .font(usesMonospace ? .body.monospacedDigit() : .body)
                        .accessibilityLabel(key.label)
                    if key.kind == .date {
                        Button {
                            value = LabelFormat.formatDate(Date())
                        } label: {
                            Image(systemName: "calendar")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Set \(key.label) to today")
                    }
                }
                if let crop, (confidence ?? 1) < 0.8 || highlightBlank {
                    Image(uiImage: crop)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 48, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))
                        .accessibilityLabel("Image of the label text this field was read from")
                }
                if let issue {
                    Text(issue).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var labelLine: some View {
        HStack(spacing: 6) {
            Text(key.label)
                .font(key.kind == .bool || isChoice ? .body : .caption)
                .foregroundStyle(key.kind == .bool || isChoice ? .primary : .secondary)
            if let confidence {
                Circle()
                    .fill(ConfidenceLevel(confidence).color)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("OCR confidence \(ConfidenceLevel(confidence).description)")
            }
            if isEdited {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Edited")
            } else if highlightBlank {
                Text("Not read")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    private var isChoice: Bool {
        if case .choice = key.kind { return true }
        return false
    }

    private var isMultiline: Bool { key.kind == .multiline || key.kind == .list }

    private var usesMonospace: Bool {
        switch key.kind {
        case .digits, .integer, .decimal, .money, .ndc, .date, .dateTime, .monthYear, .phone: true
        default: false
        }
    }

    private var keyboardType: UIKeyboardType {
        switch key.kind {
        case .digits, .integer: .numberPad
        case .decimal, .money: .decimalPad
        case .date, .dateTime, .monthYear, .ndc: .numbersAndPunctuation
        case .phone: .phonePad
        default: .default
        }
    }

    private var autocapitalization: TextInputAutocapitalization {
        switch key {
        case .drugName, .strengthForm, .patientState, .pharmacyState, .quantityUnit, .storeCode, .tp, .gr, .drugStorageType, .stickerTP:
            .characters
        default:
            key.kind == .multiline || key.kind == .list ? .sentences : .words
        }
    }
}

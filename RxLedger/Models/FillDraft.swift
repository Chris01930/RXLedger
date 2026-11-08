import Foundation

/// An editable, string-based snapshot of every label field. Used by the parser output,
/// the review/manual-entry/edit form, JSON backup and CSV export. Values are converted to
/// typed values only when applied to a `Fill`.
struct FillDraft: Equatable, Codable {
    private(set) var values: [FieldKey: String] = [:]

    init() {}

    init(_ values: [FieldKey: String]) {
        for (k, v) in values { self[k] = v }
    }

    subscript(key: FieldKey) -> String {
        get { values[key] ?? "" }
        set { values[key] = newValue.isEmpty ? nil : newValue }
    }

    // MARK: Typed accessors

    func text(_ key: FieldKey) -> String? {
        let t = self[key].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func int(_ key: FieldKey) -> Int? {
        guard let t = text(key) else { return nil }
        return Int(t)
    }

    func double(_ key: FieldKey) -> Double? {
        guard let t = text(key) else { return nil }
        return Double(t)
    }

    func money(_ key: FieldKey) -> Decimal? {
        guard let t = text(key) else { return nil }
        return LabelFormat.parseMoney(t)
    }

    func date(_ key: FieldKey) -> Date? {
        guard let t = text(key) else { return nil }
        return LabelFormat.parseDate(t)
    }

    func dateTime(_ key: FieldKey) -> Date? {
        guard let t = text(key) else { return nil }
        return LabelFormat.parseDateTime(t)
    }

    func bool(_ key: FieldKey) -> Bool { self[key] == "true" }

    mutating func setBool(_ key: FieldKey, _ value: Bool) { self[key] = value ? "true" : "" }

    func list(_ key: FieldKey) -> [String] {
        self[key]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool { values.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    var displayName: String {
        Fill.makeDisplayName(drugName: text(.drugName) ?? "", strengthForm: text(.strengthForm))
    }

    // MARK: Validation

    /// Field-level problems that would cause data to be lost on save. Empty means OK to save.
    func validationIssues() -> [FieldKey: String] {
        var issues: [FieldKey: String] = [:]
        if text(.drugName) == nil { issues[.drugName] = "Drug name is required." }
        for key in FieldKey.allCases {
            guard let t = text(key) else { continue }
            switch key.kind {
            case .integer where Int(t) == nil:
                issues[key] = "Enter a whole number."
            case .decimal where Double(t) == nil:
                issues[key] = "Enter a number."
            case .money where LabelFormat.parseMoney(t) == nil:
                issues[key] = "Enter an amount like 12.34."
            case .date where LabelFormat.parseDate(t) == nil:
                issues[key] = "Use M/D/YY."
            case .dateTime where LabelFormat.parseDateTime(t) == nil:
                issues[key] = "Use M/D/YY H:MM AM."
            case .ndc where NDC.normalize(t) == nil:
                issues[key] = "Use 5-4-2 digits, e.g. 00093-1048-01."
            case .digits where !t.allSatisfy(\.isASCIIDigit):
                issues[key] = "Digits only."
            case .monthYear where t.range(of: #"^\d{1,2}/\d{2}$"#, options: .regularExpression) == nil:
                issues[key] = "Use M/YY."
            default:
                break
            }
        }
        return issues
    }

    /// Keys whose values differ between two drafts.
    func changedKeys(comparedTo other: FillDraft) -> Set<FieldKey> {
        Set(FieldKey.allCases.filter { self.text($0) != other.text($0) })
    }

    // MARK: Codable (string-keyed so backups are readable and stable)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        for (k, v) in raw { if let key = FieldKey(rawValue: k) { self[key] = v } }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }
}

// MARK: - Fill <-> Draft

extension Fill {
    func draft() -> FillDraft {
        var d = FillDraft()
        for key in FieldKey.allCases { d[key] = stringValue(for: key) }
        return d
    }

    func stringValue(for key: FieldKey) -> String {
        func s(_ v: String?) -> String { v ?? "" }
        func i(_ v: Int?) -> String { v.map(String.init) ?? "" }
        func b(_ v: Bool) -> String { v ? "true" : "" }
        switch key {
        case .storeCode: return s(storeCode)
        case .binSlot: return s(binSlot)
        case .promisedAt: return LabelFormat.formatDateTime(promisedAt)
        case .scriptsCount: return i(scriptsCount)
        case .readyFill: return b(readyFill)
        case .barcode: return s(barcode)
        case .patientName: return s(patientName)
        case .patientStreet: return s(patientStreet)
        case .patientCity: return s(patientCity)
        case .patientState: return s(patientState)
        case .patientZip: return s(patientZip)
        case .patientDOB: return s(patientDOB)
        case .patientPhone: return s(patientPhone)
        case .drugName: return drugName
        case .strengthForm: return s(strengthForm)
        case .commonBrands: return s(commonBrands)
        case .directions: return s(directions)
        case .scheduleMorning: return s(scheduleMorning)
        case .scheduleMidday: return s(scheduleMidday)
        case .scheduleEvening: return s(scheduleEvening)
        case .scheduleBedtime: return s(scheduleBedtime)
        case .importantInfo: return importantInfo.joined(separator: "\n")
        case .pharmacyName: return s(pharmacyName)
        case .pharmacyStreet: return s(pharmacyStreet)
        case .pharmacyCity: return s(pharmacyCity)
        case .pharmacyState: return s(pharmacyState)
        case .pharmacyZip: return s(pharmacyZip)
        case .storeNumber: return s(storeNumber)
        case .storePhone: return s(storePhone)
        case .rxNumber: return s(rxNumber)
        case .fillNumber: return s(fillNumber)
        case .refillFlag: return b(refillFlag)
        case .retailPrice: return LabelFormat.moneyString(retailPrice)
        case .ndc: return s(ndc)
        case .daw: return i(daw)
        case .quantity: return quantity.map(LabelFormat.formatNumber) ?? ""
        case .quantityUnit: return s(quantityUnit)
        case .capType: return s(capType)
        case .mfrPackage: return s(mfrPackage)
        case .refillsRemaining: return i(refillsRemaining)
        case .manufacturer: return s(manufacturer)
        case .prescriberName: return s(prescriberName)
        case .daysSupply: return i(daysSupply)
        case .dateFilled: return LabelFormat.formatDate(dateFilled)
        case .amountDue: return LabelFormat.moneyString(amountDue)
        case .insurancePlanName: return s(insurancePlanName)
        case .bin: return s(bin)
        case .tp: return s(tp)
        case .gr: return s(gr)
        case .authNumber: return s(authNumber)
        case .pharmacyNotes: return s(pharmacyNotes)
        case .drugStorageType: return s(drugStorageType)
        case .stickerDate: return LabelFormat.formatDate(stickerDate)
        case .stickerTP: return s(stickerTP)
        }
    }

    /// Copies every field from the draft onto this fill, recomputing derived values
    /// (display name, normalized NDC, dedupe key). Does not touch relationships or metadata
    /// other than `updatedAt`.
    func apply(_ d: FillDraft) {
        storeCode = d.text(.storeCode)
        binSlot = d.text(.binSlot)
        promisedAt = d.dateTime(.promisedAt)
        scriptsCount = d.int(.scriptsCount)
        readyFill = d.bool(.readyFill)
        barcode = d.text(.barcode)

        patientName = d.text(.patientName)
        patientStreet = d.text(.patientStreet)
        patientCity = d.text(.patientCity)
        patientState = d.text(.patientState)?.uppercased()
        patientZip = d.text(.patientZip)
        patientDOB = d.text(.patientDOB)
        patientPhone = d.text(.patientPhone)

        drugName = d.text(.drugName) ?? ""
        strengthForm = d.text(.strengthForm)
        displayName = Fill.makeDisplayName(drugName: drugName, strengthForm: strengthForm)
        commonBrands = d.text(.commonBrands)
        directions = d.text(.directions)
        scheduleMorning = d.text(.scheduleMorning)
        scheduleMidday = d.text(.scheduleMidday)
        scheduleEvening = d.text(.scheduleEvening)
        scheduleBedtime = d.text(.scheduleBedtime)
        importantInfo = d.list(.importantInfo)

        pharmacyName = d.text(.pharmacyName)
        pharmacyStreet = d.text(.pharmacyStreet)
        pharmacyCity = d.text(.pharmacyCity)
        pharmacyState = d.text(.pharmacyState)?.uppercased()
        pharmacyZip = d.text(.pharmacyZip)
        storeNumber = d.text(.storeNumber)
        storePhone = d.text(.storePhone)

        rxNumber = d.text(.rxNumber)
        fillNumber = d.text(.fillNumber).map { $0.count == 1 ? "0" + $0 : $0 }
        refillFlag = d.bool(.refillFlag)
        retailPrice = d.money(.retailPrice)
        ndcNormalized = NDC.normalize(d.text(.ndc))
        ndc = NDC.format542(ndcNormalized) ?? d.text(.ndc)
        daw = d.int(.daw)
        quantity = d.double(.quantity)
        quantityUnit = d.text(.quantityUnit)?.uppercased()
        capType = d.text(.capType)
        mfrPackage = d.text(.mfrPackage)
        refillsRemaining = d.int(.refillsRemaining)
        manufacturer = d.text(.manufacturer)
        prescriberName = d.text(.prescriberName)
        daysSupply = d.int(.daysSupply)
        dateFilled = d.date(.dateFilled)
        amountDue = d.money(.amountDue)

        insurancePlanName = d.text(.insurancePlanName)
        bin = d.text(.bin)
        tp = d.text(.tp)
        gr = d.text(.gr)
        authNumber = d.text(.authNumber)

        pharmacyNotes = d.text(.pharmacyNotes)

        drugStorageType = d.text(.drugStorageType)
        stickerDate = d.date(.stickerDate)
        stickerTP = d.text(.stickerTP)

        if let key = DedupeService.key(rxNumber: rxNumber, fillNumber: fillNumber, ndc: ndcNormalized, dateFilled: dateFilled) {
            dedupeKey = key
        } else if !DedupeService.isUnkeyed(dedupeKey) || dedupeKey.isEmpty {
            dedupeKey = "unkeyed-\(id.uuidString)"
        }
        updatedAt = Date()
    }
}

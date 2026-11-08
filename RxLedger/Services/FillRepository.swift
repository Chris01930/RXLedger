import Foundation
import SwiftData

/// OCR artifacts attached to a scanned fill.
struct OCRPayload {
    var rawText: String
    var lines: [OCRLine]
    var confidence: Double?
    /// Already downscaled JPEG.
    var imageData: Data?

    var linesData: Data? { try? JSONEncoder().encode(lines) }
}

/// Creates, updates and deletes fills, and keeps the related de-duplicated records
/// (`Medication`, `Pharmacy`, `Prescriber`, `InsurancePlan`, `Patient`) linked.
/// Duplicate *detection* lives in `DedupeService`; callers decide what to do with a duplicate.
@MainActor
struct FillRepository {
    let context: ModelContext

    /// Inserts a new fill. Callers should check `DedupeService.findExisting` first.
    @discardableResult
    func create(from draft: FillDraft, source: DataSource, ocr: OCRPayload?, wasEditedAfterScan: Bool = false) throws -> Fill {
        let fill = Fill(source: source)
        context.insert(fill)
        fill.apply(draft)
        attach(ocr, to: fill)
        fill.wasEditedAfterScan = source == .scan && wasEditedAfterScan
        link(fill)
        try context.save()
        return fill
    }

    /// Overwrites an existing fill with a new scan/entry, keeping its identity and original `createdAt`.
    @discardableResult
    func replace(_ existing: Fill, with draft: FillDraft, source: DataSource, ocr: OCRPayload?, wasEditedAfterScan: Bool = false) throws -> Fill {
        let originalCreatedAt = existing.createdAt
        existing.source = source
        existing.apply(draft)
        existing.rawOCRText = nil
        existing.ocrLinesData = nil
        existing.imageData = nil
        existing.ocrConfidence = nil
        attach(ocr, to: existing)
        existing.wasEditedAfterScan = source == .scan && wasEditedAfterScan
        existing.createdAt = originalCreatedAt
        link(existing)
        cleanupOrphanMedications()
        try context.save()
        return existing
    }

    /// Applies user edits to an existing fill.
    /// - Parameters:
    ///   - ocr: OCR artifacts to store when a photo was added while editing (replaces the stored text,
    ///     lines and image with the combined versions).
    ///   - ocrFilledKeys: fields filled from that photo — not counted as manual edits.
    func update(_ fill: Fill, with draft: FillDraft, ocr: OCRPayload? = nil, ocrFilledKeys: Set<FieldKey> = []) throws {
        let before = fill.draft()
        fill.apply(draft)
        if fill.source == .scan, !before.changedKeys(comparedTo: draft).subtracting(ocrFilledKeys).isEmpty {
            fill.wasEditedAfterScan = true
        }
        if let ocr { attach(ocr, to: fill) }
        link(fill)
        cleanupOrphanMedications()
        try context.save()
    }

    func delete(_ fill: Fill) throws {
        context.delete(fill)
        try context.save()
        cleanupOrphanMedications()
        try context.save()
    }

    private func attach(_ ocr: OCRPayload?, to fill: Fill) {
        guard let ocr else { return }
        fill.rawOCRText = ocr.rawText
        fill.ocrLinesData = ocr.linesData
        fill.ocrConfidence = ocr.confidence
        if let data = ocr.imageData { fill.imageData = data }
    }

    // MARK: - Linking related records

    func link(_ fill: Fill) {
        fill.medication = upsertMedication(for: fill)
        fill.pharmacy = upsertPharmacy(for: fill)
        fill.prescriber = upsertPrescriber(for: fill)
        fill.insurance = upsertInsurance(for: fill)
        fill.patient = upsertPatient(for: fill)
    }

    /// Medications with no fills left are removed (pharmacies, prescribers etc. are kept so
    /// they remain available in the manual-entry pickers).
    func cleanupOrphanMedications() {
        let all = (try? context.fetch(FetchDescriptor<Medication>())) ?? []
        for med in all where (med.fills ?? []).isEmpty {
            context.delete(med)
        }
    }

    static func normalizedText(_ s: String?) -> String {
        (s ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func medicationKey(ndcNormalized: String?, drugName: String, strengthForm: String?) -> String {
        if let ndcNormalized, !ndcNormalized.isEmpty { return "ndc:\(ndcNormalized)" }
        return "name:\(normalizedText(drugName))|\(normalizedText(strengthForm))"
    }

    private func fetch<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private func upsertMedication(for fill: Fill) -> Medication? {
        guard !fill.drugName.isEmpty else { return nil }
        let key = Self.medicationKey(ndcNormalized: fill.ndcNormalized, drugName: fill.drugName, strengthForm: fill.strengthForm)
        let all = fetch(Medication.self)
        var med = all.first { $0.matchKey == key }

        // A drug first entered manually without an NDC is adopted by the first fill that has one.
        if med == nil, fill.ndcNormalized != nil {
            let nameKey = Self.medicationKey(ndcNormalized: nil, drugName: fill.drugName, strengthForm: fill.strengthForm)
            if let byName = all.first(where: { $0.matchKey == nameKey }) {
                byName.matchKey = key
                med = byName
            }
        }

        let medication = med ?? {
            let m = Medication(matchKey: key, drugName: fill.drugName, strengthForm: fill.strengthForm)
            context.insert(m)
            return m
        }()

        // Keep descriptive fields in sync with the newest fill.
        let isNewest = (medication.fills ?? []).allSatisfy { $0.id == fill.id || $0.sortDate <= fill.sortDate }
        if isNewest || medication.displayName.isEmpty {
            medication.drugName = fill.drugName
            medication.strengthForm = fill.strengthForm
            medication.displayName = fill.displayName
            medication.ndc = fill.ndc ?? medication.ndc
            medication.commonBrands = fill.commonBrands ?? medication.commonBrands
            medication.manufacturer = fill.manufacturer ?? medication.manufacturer
        }
        return medication
    }

    private func upsertPharmacy(for fill: Fill) -> Pharmacy? {
        let store = DedupeService.digits(fill.storeNumber)
        let key: String
        if !store.isEmpty {
            key = "store:\(store)"
        } else if fill.pharmacyName != nil || fill.pharmacyStreet != nil {
            key = "name:\(Self.normalizedText(fill.pharmacyName))|\(Self.normalizedText(fill.pharmacyStreet))"
        } else {
            return nil
        }
        let p = fetch(Pharmacy.self).first { $0.matchKey == key } ?? {
            let p = Pharmacy(matchKey: key)
            context.insert(p)
            return p
        }()
        p.storeNumber = fill.storeNumber ?? p.storeNumber
        p.name = fill.pharmacyName ?? p.name
        p.street = fill.pharmacyStreet ?? p.street
        p.city = fill.pharmacyCity ?? p.city
        p.state = fill.pharmacyState ?? p.state
        p.zip = fill.pharmacyZip ?? p.zip
        p.phone = fill.storePhone ?? p.phone
        return p
    }

    private func upsertPrescriber(for fill: Fill) -> Prescriber? {
        guard let name = fill.prescriberName else { return nil }
        let key = Self.normalizedText(name)
        guard !key.isEmpty else { return nil }
        if let existing = fetch(Prescriber.self).first(where: { $0.matchKey == key }) { return existing }
        let p = Prescriber(matchKey: key, name: name)
        context.insert(p)
        return p
    }

    private func upsertInsurance(for fill: Fill) -> InsurancePlan? {
        guard fill.bin != nil || fill.insurancePlanName != nil else { return nil }
        let key = [DedupeService.digits(fill.bin), Self.normalizedText(fill.gr), Self.normalizedText(fill.insurancePlanName)]
            .joined(separator: "|")
        let plan = fetch(InsurancePlan.self).first { $0.matchKey == key } ?? {
            let p = InsurancePlan(matchKey: key)
            context.insert(p)
            return p
        }()
        plan.planName = fill.insurancePlanName ?? plan.planName
        plan.bin = fill.bin ?? plan.bin
        plan.tp = fill.tp ?? plan.tp
        plan.gr = fill.gr ?? plan.gr
        return plan
    }

    private func upsertPatient(for fill: Fill) -> Patient? {
        guard let name = fill.patientName else { return nil }
        let key = "\(Self.normalizedText(name))|\(fill.patientDOB ?? "")"
        let patient = fetch(Patient.self).first { $0.matchKey == key } ?? {
            let p = Patient(matchKey: key, name: name)
            context.insert(p)
            return p
        }()
        patient.street = fill.patientStreet ?? patient.street
        patient.city = fill.patientCity ?? patient.city
        patient.state = fill.patientState ?? patient.state
        patient.zip = fill.patientZip ?? patient.zip
        patient.dobMonthYear = fill.patientDOB ?? patient.dobMonthYear
        patient.phone = fill.patientPhone ?? patient.phone
        return patient
    }
}

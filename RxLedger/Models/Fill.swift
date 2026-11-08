import Foundation
import SwiftData

/// Where a fill record came from. Stored as a raw string (`sourceRaw`) so the model stays CloudKit-friendly.
enum DataSource: String, Codable, CaseIterable, Identifiable {
    case scan
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scan: "Scanned"
        case .manual: "Manual entry"
        }
    }

    var systemImage: String {
        switch self {
        case .scan: "doc.viewfinder"
        case .manual: "square.and.pencil"
        }
    }
}

/// One CVS label = one fill. Every printed field is stored as a snapshot on the fill itself
/// (so the reconstructed label always shows exactly what was printed), and the fill is also
/// linked to de-duplicated `Medication`, `Pharmacy`, `Prescriber`, `InsurancePlan` and `Patient` records.
///
/// CloudKit compatibility: every property is optional or has a default, no unique constraints,
/// all relationships optional with inverses.
@Model
final class Fill {
    // MARK: Metadata
    var id: UUID = UUID()
    var sourceRaw: String = DataSource.manual.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var wasEditedAfterScan: Bool = false
    var ocrConfidence: Double?
    var dedupeKey: String = ""

    // MARK: Header
    var storeCode: String?
    var binSlot: String?
    var promisedAt: Date?
    var scriptsCount: Int?
    var readyFill: Bool = false
    var barcode: String?

    // MARK: Patient band
    var patientName: String?
    var patientStreet: String?
    var patientCity: String?
    var patientState: String?
    var patientZip: String?
    /// CVS prints month/year only, e.g. "4/71".
    var patientDOB: String?
    var patientPhone: String?

    // MARK: Prescription information
    var drugName: String = ""
    var strengthForm: String?
    var displayName: String = ""
    var commonBrands: String?
    var directions: String?
    var scheduleMorning: String?
    var scheduleMidday: String?
    var scheduleEvening: String?
    var scheduleBedtime: String?
    var importantInfo: [String] = []

    // MARK: Receipt & refill information
    var pharmacyName: String?
    var pharmacyStreet: String?
    var pharmacyCity: String?
    var pharmacyState: String?
    var pharmacyZip: String?
    var storeNumber: String?
    var storePhone: String?
    var rxNumber: String?
    /// Two-digit fill number printed after the Rx number, e.g. "01".
    var fillNumber: String?
    var refillFlag: Bool = false
    var insurancePlanName: String?
    var bin: String?
    var tp: String?
    var gr: String?
    var authNumber: String?
    var retailPrice: Decimal?
    /// As printed, 5-4-2 hyphenated.
    var ndc: String?
    /// 11 digits, no hyphens.
    var ndcNormalized: String?
    var daw: Int?
    var quantity: Double?
    var quantityUnit: String?
    var capType: String?
    var mfrPackage: String?
    var refillsRemaining: Int?
    var manufacturer: String?
    var prescriberName: String?
    var daysSupply: Int?
    var dateFilled: Date?
    /// The copay.
    var amountDue: Decimal?

    // MARK: Notes
    var pharmacyNotes: String?

    // MARK: Side sticker
    var drugStorageType: String?
    var stickerDate: Date?
    var stickerTP: String?

    // MARK: OCR artifacts (kept so the parser can be re-run later)
    var rawOCRText: String?
    /// JSON-encoded `[OCRLine]` (text, confidence, normalized bounding box).
    var ocrLinesData: Data?
    /// Downscaled JPEG (≤ 1600 px long edge) of the source image.
    @Attribute(.externalStorage) var imageData: Data?

    // MARK: Relationships
    var medication: Medication?
    var pharmacy: Pharmacy?
    var prescriber: Prescriber?
    var insurance: InsurancePlan?
    var patient: Patient?

    init(source: DataSource) {
        self.id = UUID()
        self.sourceRaw = source.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.dedupeKey = "unkeyed-\(id.uuidString)"
    }

    var source: DataSource {
        get { DataSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    /// Date used for ordering: date filled, else when it was recorded.
    var sortDate: Date { dateFilled ?? createdAt }

    var nextRefillEstimate: Date? {
        guard let dateFilled, let daysSupply, daysSupply > 0 else { return nil }
        return LabelFormat.calendar.date(byAdding: .day, value: daysSupply, to: dateFilled)
    }

    var quantityText: String? {
        guard let quantity else { return nil }
        let q = LabelFormat.formatNumber(quantity)
        if let unit = quantityUnit, !unit.isEmpty { return "\(q) \(unit)" }
        return q
    }

    var ocrLines: [OCRLine] {
        guard let ocrLinesData else { return [] }
        return (try? JSONDecoder().decode([OCRLine].self, from: ocrLinesData)) ?? []
    }

    static func makeDisplayName(drugName: String, strengthForm: String?) -> String {
        [drugName, strengthForm ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

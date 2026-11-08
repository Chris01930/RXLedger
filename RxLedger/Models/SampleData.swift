import Foundation
import SwiftData

/// Fictional sample data for previews and `-seedSampleData` debug launches.
@MainActor
enum SampleData {
    static var metforminDraft: FillDraft {
        FillDraft([
            .storeCode: "NE", .binSlot: "116", .promisedAt: "6/23/26 3:00 PM", .scriptsCount: "2", .readyFill: "true",
            .barcode: "258136301062326",
            .patientName: "Sample, Alex J", .patientStreet: "12 Example St", .patientCity: "Boston", .patientState: "MA",
            .patientZip: "02110", .patientDOB: "4/80", .patientPhone: "(617) 555-0142",
            .drugName: "IC METFORMIN HCL", .strengthForm: "500 MG TABLET", .commonBrands: "Glucophage",
            .directions: "Take 1 tablet by mouth every day with evening meal",
            .scheduleMorning: "", .scheduleMidday: "", .scheduleEvening: "1", .scheduleBedtime: "",
            .importantInfo: "Take with food\nDo not drink alcohol while taking this medication\nMay cause stomach upset",
            .pharmacyName: "CVS Pharmacy", .pharmacyStreet: "100 Main St", .pharmacyCity: "Boston", .pharmacyState: "MA",
            .pharmacyZip: "02110", .storeNumber: "1234", .storePhone: "(617) 555-0100",
            .rxNumber: "2581363", .fillNumber: "01", .refillFlag: "true",
            .insurancePlanName: "CAREMARK", .bin: "004336", .tp: "ADV", .gr: "RX1234", .authNumber: "123456789",
            .retailPrice: "14.99", .ndc: "00093-1048-01", .daw: "0", .quantity: "30", .quantityUnit: "EA",
            .capType: "Safety", .mfrPackage: "No", .refillsRemaining: "5", .manufacturer: "TEVA USA",
            .prescriberName: "Jordan Lee", .daysSupply: "30", .dateFilled: "6/23/26", .amountDue: "0.00",
            .drugStorageType: "FAST MOVER", .stickerDate: "6/23/26", .stickerTP: "ADV",
        ])
    }

    static var lisinoprilDraft: FillDraft {
        var d = metforminDraft
        d[.drugName] = "IC LISINOPRIL"
        d[.strengthForm] = "10 MG TABLET"
        d[.commonBrands] = "Prinivil, Zestril"
        d[.directions] = "Take 1 tablet by mouth every morning"
        d[.scheduleMorning] = "1"
        d[.scheduleEvening] = ""
        d[.importantInfo] = "May cause dizziness\nCheck with your doctor before using potassium supplements"
        d[.rxNumber] = "2590417"
        d[.fillNumber] = "03"
        d[.ndc] = "68180-0514-01"
        d[.manufacturer] = "LUPIN PHARMA"
        d[.retailPrice] = "22.49"
        d[.amountDue] = "2.50"
        d[.quantity] = "90"
        d[.daysSupply] = "90"
        d[.refillsRemaining] = "2"
        d[.dateFilled] = "5/2/26"
        return d
    }

    static func seedIfEmpty(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Fill>())) ?? 0
        guard count == 0 else { return }
        let repo = FillRepository(context: context)

        _ = try? repo.create(from: metforminDraft, source: .scan, ocr: OCRPayload(rawText: "(sample)", lines: [], confidence: 0.93))

        var older = metforminDraft
        older[.fillNumber] = "00"
        older[.dateFilled] = "5/24/26"
        older[.refillsRemaining] = "6"
        older[.amountDue] = "4.00"
        _ = try? repo.create(from: older, source: .scan, ocr: OCRPayload(rawText: "(sample)", lines: [], confidence: 0.81), wasEditedAfterScan: true)

        _ = try? repo.create(from: lisinoprilDraft, source: .manual, ocr: nil)

        var vitamin = FillDraft()
        vitamin[.drugName] = "ATORVASTATIN"
        vitamin[.strengthForm] = "20 MG TABLET"
        vitamin[.directions] = "Take 1 tablet by mouth at bedtime"
        vitamin[.scheduleBedtime] = "1"
        vitamin[.dateFilled] = "11/30/25"
        vitamin[.quantity] = "30"
        vitamin[.quantityUnit] = "EA"
        vitamin[.daysSupply] = "30"
        vitamin[.amountDue] = "5.00"
        vitamin[.retailPrice] = "31.20"
        vitamin[.prescriberName] = "Jordan Lee"
        if let f = try? repo.create(from: vitamin, source: .manual, ocr: nil) {
            f.medication?.isActive = false
        }
        try? context.save()
    }

    /// First fill in the preview container (for previews of detail screens).
    static func previewFill() -> Fill {
        let context = PersistenceController.preview.mainContext
        let fills = (try? context.fetch(FetchDescriptor<Fill>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return fills.first!
    }

    static func previewMedication() -> Medication {
        previewFill().medication!
    }
}

import Foundation

/// Groups of fields, in label order, used by the editor form.
enum LabelSection: String, CaseIterable, Identifiable {
    case header, patient, prescription, pharmacy, refill, insurance, notes, sticker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .header: "Header"
        case .patient: "Patient"
        case .prescription: "Prescription Information"
        case .pharmacy: "Pharmacy"
        case .refill: "Receipt & Refill Information"
        case .insurance: "Insurance Information"
        case .notes: "Notes from the Pharmacy"
        case .sticker: "Side Sticker"
        }
    }
}

enum FieldKind: Equatable {
    case text
    case multiline
    /// One entry per line.
    case list
    case digits
    case integer
    case decimal
    case money
    /// M/D/YY
    case date
    /// M/D/YY H:MM AM
    case dateTime
    /// M/YY
    case monthYear
    case phone
    case ndc
    case bool
    case choice([String])
}

/// Every editable/parsable field on the label. Raw values match the `Fill` property names,
/// and are used as stable keys in JSON backups and CSV export.
enum FieldKey: String, CaseIterable, Codable, Identifiable {
    // Header
    case storeCode, binSlot, promisedAt, scriptsCount, readyFill, barcode
    // Patient band
    case patientName, patientStreet, patientCity, patientState, patientZip, patientDOB, patientPhone
    // Prescription information
    case drugName, strengthForm, commonBrands, directions
    case scheduleMorning, scheduleMidday, scheduleEvening, scheduleBedtime
    case importantInfo
    // Pharmacy
    case pharmacyName, pharmacyStreet, pharmacyCity, pharmacyState, pharmacyZip, storeNumber, storePhone
    // Receipt & refill
    case rxNumber, fillNumber, refillFlag, retailPrice, ndc, daw, quantity, quantityUnit
    case capType, mfrPackage, refillsRemaining, manufacturer, prescriberName, daysSupply, dateFilled, amountDue
    // Insurance
    case insurancePlanName, bin, tp, gr, authNumber
    // Notes
    case pharmacyNotes
    // Side sticker
    case drugStorageType, stickerDate, stickerTP

    var id: String { rawValue }

    var label: String {
        switch self {
        case .storeCode: "Store code"
        case .binSlot: "Bin / slot"
        case .promisedAt: "Promised"
        case .scriptsCount: "# Scripts"
        case .readyFill: "ReadyFill"
        case .barcode: "Barcode digits"
        case .patientName: "Name (Last, First M)"
        case .patientStreet: "Street"
        case .patientCity: "City"
        case .patientState: "State"
        case .patientZip: "ZIP"
        case .patientDOB: "DOB (M/YY)"
        case .patientPhone: "Phone"
        case .drugName: "Drug name"
        case .strengthForm: "Strength / form"
        case .commonBrands: "Common brand(s)"
        case .directions: "Directions"
        case .scheduleMorning: "Morning"
        case .scheduleMidday: "Midday"
        case .scheduleEvening: "Evening"
        case .scheduleBedtime: "Bedtime"
        case .importantInfo: "Important information"
        case .pharmacyName: "Pharmacy name"
        case .pharmacyStreet: "Street"
        case .pharmacyCity: "City"
        case .pharmacyState: "State"
        case .pharmacyZip: "ZIP"
        case .storeNumber: "Store #"
        case .storePhone: "Store phone"
        case .rxNumber: "Rx number"
        case .fillNumber: "Fill number"
        case .refillFlag: "RF (refill) flag"
        case .retailPrice: "Retail price"
        case .ndc: "NDC"
        case .daw: "DAW"
        case .quantity: "Quantity"
        case .quantityUnit: "Quantity unit"
        case .capType: "Cap"
        case .mfrPackage: "Mfr package"
        case .refillsRemaining: "Refills remaining"
        case .manufacturer: "Manufacturer"
        case .prescriberName: "Prescriber"
        case .daysSupply: "Days supply"
        case .dateFilled: "Date filled"
        case .amountDue: "Amount due (copay)"
        case .insurancePlanName: "Plan name"
        case .bin: "BIN"
        case .tp: "TP"
        case .gr: "GR"
        case .authNumber: "Auth #"
        case .pharmacyNotes: "Notes"
        case .drugStorageType: "Drug storage type"
        case .stickerDate: "Sticker date"
        case .stickerTP: "Sticker TP"
        }
    }

    var section: LabelSection {
        switch self {
        case .storeCode, .binSlot, .promisedAt, .scriptsCount, .readyFill, .barcode: .header
        case .patientName, .patientStreet, .patientCity, .patientState, .patientZip, .patientDOB, .patientPhone: .patient
        case .drugName, .strengthForm, .commonBrands, .directions, .scheduleMorning, .scheduleMidday,
             .scheduleEvening, .scheduleBedtime, .importantInfo: .prescription
        case .pharmacyName, .pharmacyStreet, .pharmacyCity, .pharmacyState, .pharmacyZip, .storeNumber, .storePhone: .pharmacy
        case .rxNumber, .fillNumber, .refillFlag, .retailPrice, .ndc, .daw, .quantity, .quantityUnit, .capType,
             .mfrPackage, .refillsRemaining, .manufacturer, .prescriberName, .daysSupply, .dateFilled, .amountDue: .refill
        case .insurancePlanName, .bin, .tp, .gr, .authNumber: .insurance
        case .pharmacyNotes: .notes
        case .drugStorageType, .stickerDate, .stickerTP: .sticker
        }
    }

    var kind: FieldKind {
        switch self {
        case .promisedAt: .dateTime
        case .scriptsCount, .daw, .refillsRemaining, .daysSupply: .integer
        case .readyFill, .refillFlag: .bool
        case .barcode, .rxNumber, .fillNumber, .bin, .storeNumber: .digits
        case .patientDOB: .monthYear
        case .patientPhone, .storePhone: .phone
        case .directions, .pharmacyNotes: .multiline
        case .importantInfo: .list
        case .retailPrice, .amountDue: .money
        case .ndc: .ndc
        case .quantity: .decimal
        case .capType: .choice(["Safety", "Non-Safety"])
        case .mfrPackage: .choice(["Yes", "No"])
        case .dateFilled, .stickerDate: .date
        default: .text
        }
    }

    var placeholder: String {
        switch kind {
        case .date: "M/D/YY"
        case .dateTime: "M/D/YY H:MM AM"
        case .monthYear: "M/YY"
        case .phone: "(555) 555-5555"
        case .ndc: "00000-0000-00"
        case .money: "0.00"
        case .list: "One item per line"
        default:
            switch self {
            case .fillNumber: "01"
            case .quantityUnit: "EA"
            case .patientState, .pharmacyState: "ST"
            default: ""
            }
        }
    }

    static func fields(in section: LabelSection) -> [FieldKey] {
        allCases.filter { $0.section == section }
    }
}

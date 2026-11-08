import Foundation
import Testing
@testable import RxLedger

private final class FixtureBundleToken {}

/// Loads a fixture from Tests/Fixtures. Drop real OCR dumps (one OCR line per text line) in there.
func loadFixture(_ name: String) throws -> String {
    let bundle = Bundle(for: FixtureBundleToken.self)
    let url = try #require(bundle.url(forResource: name, withExtension: "txt"), "Missing fixture \(name).txt")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("CVSLabelParser")
struct CVSLabelParserTests {
    let parser = CVSLabelParser()

    @Test("Clean label: every field")
    func cleanLabel() throws {
        let r = parser.parse(text: try loadFixture("cvs_label_clean"))

        // Header
        #expect(r[.storeCode] == "NE")
        #expect(r[.binSlot] == "116")
        #expect(r[.promisedAt] == "6/23/26 3:00 PM")
        #expect(r[.scriptsCount] == "2")
        #expect(r[.readyFill] == "true")
        #expect(r[.barcode] == "2581363010623")

        // Patient band
        #expect(r[.patientName] == "Sample, Alex J")
        #expect(r[.patientStreet] == "12 Example St")
        #expect(r[.patientCity] == "Boston")
        #expect(r[.patientState] == "MA")
        #expect(r[.patientZip] == "02110")
        #expect(r[.patientDOB] == "4/80")
        #expect(r[.patientPhone] == "(617) 555-0142")

        // Prescription information
        #expect(r[.drugName] == "IC METFORMIN HCL")
        #expect(r[.strengthForm] == "500 MG TABLET")
        #expect(r[.commonBrands] == "Glucophage")
        #expect(r[.directions] == "Take 1 tablet by mouth every day with evening meal")
        #expect(r[.scheduleMorning] == nil)
        #expect(r[.scheduleMidday] == nil)
        #expect(r[.scheduleEvening] == "1")
        #expect(r[.scheduleBedtime] == nil)
        #expect(r.draft.list(.importantInfo) == [
            "Take with food",
            "Do not drink alcohol while taking this medication",
            "May cause stomach upset",
        ])

        // Pharmacy
        #expect(r[.pharmacyName] == "CVS Pharmacy")
        #expect(r[.pharmacyStreet] == "100 Main St")
        #expect(r[.pharmacyCity] == "Boston")
        #expect(r[.pharmacyState] == "MA")
        #expect(r[.pharmacyZip] == "02110")
        #expect(r[.storeNumber] == "1234")
        #expect(r[.storePhone] == "(617) 555-0100")

        // Receipt & refill
        #expect(r[.rxNumber] == "2581363")
        #expect(r[.fillNumber] == "01")
        #expect(r[.refillFlag] == "true")
        #expect(r[.insurancePlanName] == "CAREMARK")
        #expect(r[.bin] == "004336")
        #expect(r[.tp] == "ADV")
        #expect(r[.gr] == "RX1234")
        #expect(r[.authNumber] == "123456789")
        #expect(r[.retailPrice] == "14.99")
        #expect(r[.ndc] == "00093-1048-01")
        #expect(r[.daw] == "0")
        #expect(r[.quantity] == "30")
        #expect(r[.quantityUnit] == "EA")
        #expect(r[.capType] == "Safety")
        #expect(r[.mfrPackage] == "No")
        #expect(r[.refillsRemaining] == "5")
        #expect(r[.manufacturer] == "TEVA USA")
        #expect(r[.prescriberName] == "Jordan Lee")
        #expect(r[.daysSupply] == "30")
        #expect(r[.dateFilled] == "6/23/26")
        #expect(r[.amountDue] == "0.00")

        // Notes are empty; side sticker present
        #expect(r[.pharmacyNotes] == nil)
        #expect(r[.drugStorageType] == "FAST MOVER")
        #expect(r[.stickerDate] == "6/23/26")
        #expect(r[.stickerTP] == "ADV")

        #expect(r.draft.validationIssues().isEmpty)
        #expect(r.meanConfidence == 1.0)
    }

    @Test("Garbled label: O/0, l/1, S/5 confusions and a dropped $ are repaired")
    func garbledLabel() throws {
        let r = parser.parse(text: try loadFixture("cvs_label_garbled"))

        #expect(r[.binSlot] == "116")
        #expect(r[.promisedAt] == "6/23/26 3:00 PM")
        #expect(r[.scriptsCount] == "2")
        #expect(r[.barcode] == "2581363010623")
        #expect(r[.patientZip] == "02110")
        #expect(r[.patientDOB] == "4/80")
        #expect(r[.patientPhone] == "(617) 555-0142")
        #expect(r[.storeNumber] == "1234")
        #expect(r[.storePhone] == "(617) 555-0100")
        #expect(r[.rxNumber] == "2581363")
        #expect(r[.fillNumber] == "01")
        #expect(r[.bin] == "004336")
        #expect(r[.retailPrice] == "14.99")
        #expect(r[.ndc] == "00093-1048-01")
        #expect(r[.daw] == "0")
        #expect(r[.quantity] == "30")
        #expect(r[.daysSupply] == "30")
        #expect(r[.dateFilled] == "6/23/26")
        #expect(r[.amountDue] == "0.00")

        // Repaired values carry lower confidence than untouched ones.
        let ndcConfidence = try #require(r.fields[.ndc]?.confidence)
        let drugConfidence = try #require(r.fields[.drugName]?.confidence)
        #expect(ndcConfidence < drugConfidence)

        // Sticker absent: no failure, no values.
        #expect(r[.drugStorageType] == nil)
        #expect(r[.stickerDate] == nil)
        #expect(r[.stickerTP] == nil)
    }

    @Test("SEE DIRECTIONS, single-line drug, wrapped brands, no fill number, 4-4-2 NDC, notes")
    func seeDirectionsLabel() throws {
        let r = parser.parse(text: try loadFixture("cvs_label_see_directions"))

        #expect(r[.drugName] == "PREDNISONE")
        #expect(r[.strengthForm] == "10 MG TABLET")
        #expect(r[.commonBrands] == "Deltasone, Rayos")
        #expect(r[.directions] == "Take as directed on the taper schedule")
        for key in [FieldKey.scheduleMorning, .scheduleMidday, .scheduleEvening, .scheduleBedtime] {
            #expect(r[key] == "SEE DIRECTIONS")
        }
        #expect(r[.patientDOB] == "4/80")
        #expect(r[.patientPhone] == "(617) 555-0142")
        #expect(r[.rxNumber] == "2611002")
        #expect(r[.fillNumber] == nil)
        #expect(r[.refillFlag] == nil)
        #expect(r[.ndc] == "00054-4728-25")
        #expect(r[.refillsRemaining] == "0")
        #expect(r[.amountDue] == "3.75")
        #expect(r[.readyFill] == nil)
        #expect(r[.pharmacyNotes] == "Call if you have questions about the taper.")
    }

    @Test("Anchor score separates labels from other text")
    func anchorScore() throws {
        let label = OCRLine.fromPlainText(try loadFixture("cvs_label_clean"))
        let noise = OCRLine.fromPlainText("Grocery list\nMilk\nEggs\nBread")
        #expect(CVSLabelParser.anchorScore(label) > 20)
        #expect(CVSLabelParser.anchorScore(noise) == 0)
    }

    @Test("Values split across OCR observations on the same visual row")
    func geometryRows() {
        // Two separate Vision observations on one baseline, plus a value printed below its anchor.
        let lines = [
            OCRLine(text: "NDC: 00093-1048-01", confidence: 0.9, boundingBox: CGRect(x: 0.05, y: 0.50, width: 0.4, height: 0.03)),
            OCRLine(text: "DAW: 0", confidence: 0.6, boundingBox: CGRect(x: 0.55, y: 0.505, width: 0.2, height: 0.03)),
            OCRLine(text: "PRSCBR:", confidence: 0.9, boundingBox: CGRect(x: 0.05, y: 0.45, width: 0.15, height: 0.03)),
            OCRLine(text: "Jordan Lee", confidence: 0.7, boundingBox: CGRect(x: 0.06, y: 0.41, width: 0.2, height: 0.03)),
        ]
        let r = CVSLabelParser().parse(lines: lines)
        #expect(r[.ndc] == "00093-1048-01")
        #expect(r[.daw] == "0")
        #expect(r.fields[.daw]?.confidence == 0.6)
        #expect(r[.prescriberName] == "Jordan Lee")
        #expect(r.boundingBox(for: .daw) != nil)
    }

    @Test("Value cleaners", arguments: [
        ("$12.34", "12.34"), ("S12.34", "12.34"), ("l2.3O", "12.30"), ("$ 4.00", "4.00"), ("0,99", "0.99"),
    ])
    func money(input: String, expected: String) {
        #expect(CVSLabelParser.cleanMoney(input)?.value == expected)
    }

    @Test func dates() {
        #expect(CVSLabelParser.cleanDate("6/23/26")?.value == "6/23/26")
        #expect(CVSLabelParser.cleanDate("O6/O1/2026")?.value == "6/1/26")
        #expect(CVSLabelParser.cleanDate("13/45/26") == nil)
        #expect(CVSLabelParser.cleanDateTime("6/23/26, 3:00 PM")?.value == "6/23/26 3:00 PM")
        #expect(CVSLabelParser.cleanDateTime("6/23/26 11:3O am")?.value == "6/23/26 11:30 AM")
    }
}

import CoreGraphics
import Testing
@testable import RxLedger

/// The real CVS bag-tag layout, reproduced as OCR lines with geometry (positions taken from actual
/// Vision output on a photographed label; all personal values replaced with fictional ones).
@Suite("Real CVS layout")
struct RealLayoutTests {
    private func L(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Double = 1) -> OCRLine {
        OCRLine(text: text, confidence: c, boundingBox: CGRect(x: x, y: y, width: w, height: h))
    }

    private var lines: [OCRLine] {
        [
            L("Promised: 6/20/26, 12:00 PM", 0.479, 0.932, 0.289, 0.030, 0.5),
            L("# Scripts: 01", 0.476, 0.928, 0.090, 0.014),
            L("ReadyFiT™", 0.658, 0.922, 0.060, 0.015, 0.3),
            L("NE", 0.241, 0.884, 0.089, 0.045),
            L("59", 0.368, 0.890, 0.043, 0.026),
            L("Sample, Alex J", 0.239, 0.849, 0.261, 0.024),
            L("12 Example St, Boston. MA 02110", 0.238, 0.835, 0.239, 0.018),
            L("DOB: 4/80", 0.236, 0.828, 0.069, 0.011),
            L("TEL: (617) 555-0142", 0.348, 0.823, 0.121, 0.013),
            L("Prescription Information", 0.239, 0.795, 0.270, 0.022),
            L("www.cvs.com/druginfo", 0.603, 0.789, 0.095, 0.014),
            L("27 1234567 000 000 00 0000500", 0.514, 0.870, 0.206, 0.025),
            L("MORNING", 0.244, 0.750, 0.057, 0.011),
            L("MIDDAY", 0.250, 0.709, 0.046, 0.009),
            L("IC LISINOPRIL 10 MG", 0.390, 0.757, 0.243, 0.027, 0.5),
            L("TABLET", 0.394, 0.741, 0.124, 0.020),
            L("Common brand(s): Zestril", 0.393, 0.727, 0.148, 0.019),
            L("Take 1 tablet by mouth every day", 0.393, 0.700, 0.372, 0.029),
            L("SEE DIRECTIONS", 0.31, 0.60, 0.03, 0.17, 0.5),   // sideways text
            L("EVENING", 0.247, 0.664, 0.046, 0.011),
            L("N-nuIMe", 0.244, 0.623, 0.046, 0.004, 0.3),      // garbled BEDTIME
            L("A PHARMACY ADVICE*", 0.261, 0.606, 0.092, 0.011, 0.5),
            L("See back for more information", 0.224, 0.593, 0.147, 0.011),
            L("Important Information", 0.397, 0.631, 0.170, 0.015),
            L("- This medication may cause dizziness.", 0.387, 0.617, 0.248, 0.020, 0.5),
            L("- May take with or without food.", 0.387, 0.601, 0.297, 0.021),
            L("Swallow. Do not chew.", 0.388, 0.592, 0.144, 0.015),
            L("Receipt & Refill Information", 0.224, 0.463, 0.308, 0.020),
            L("CVS Pharmacy", 0.227, 0.442, 0.124, 0.015),
            L("STORE#: 0123", 0.414, 0.438, 0.078, 0.011),
            L("100 Main St, E Bos", 0.224, 0.429, 0.109, 0.011),
            L("Boston. MA 02110", 0.224, 0.420, 0.115, 0.011),
            L("IC LISINOPRIL 10 MG", 0.517, 0.433, 0.184, 0.015),
            L("TABLET", 0.520, 0.418, 0.092, 0.013),
            L("STORE TEL: (617) 555-0100", 0.227, 0.392, 0.213, 0.015),
            L("RX: 1234567", 0.224, 0.371, 0.152, 0.019),
            L("RI", 0.454, 0.381, 0.017, 0.015, 0.3),
            L("00", 0.408, 0.371, 0.032, 0.017),
            L("INSURANCE INFORMATION:", 0.221, 0.351, 0.152, 0.011),
            L("(1 BOX)", 0.517, 0.352, 0.060, 0.013),
            L("CAREMARK BIN 004336", 0.221, 0.338, 0.178, 0.011),
            L("TP: 12345", 0.221, 0.330, 0.037, 0.011),
            L("GR: EXAMPLERX", 0.284, 0.328, 0.069, 0.011),
            L("AUTHA: 111222333444555666", 0.374, 0.327, 0.126, 0.011),
            L("NDC: 00093-1048-01", 0.517, 0.379, 0.152, 0.011),
            L("QTY: 30 EA", 0.517, 0.362, 0.089, 0.013, 0.5),
            L("DAW: 0", 0.698, 0.377, 0.055, 0.013, 0.5),
            L("CAP: Safety", 0.514, 0.300, 0.092, 0.013),
            L("MFR PKG: Yes", 0.652, 0.300, 0.103, 0.013, 0.5),
            L("REFILL: 11 by 6/23/27", 0.514, 0.308 - 0.02, 0.144, 0.013, 0.5),
            L("MFR: TEVA USA", 0.514, 0.275, 0.178, 0.013),
            L("PRSCBR: Jordan Lee", 0.511, 0.262, 0.158, 0.011),
            L("DAYS SUPPLY:", 0.511, 0.248, 0.083, 0.014),
            L("30", 0.595, 0.250, 0.026, 0.011),
            L("DATE FILLED: 6/23/26", 0.511, 0.236, 0.132, 0.013),
            L("RETAIL PRICE:$1,311.99", 0.221, 0.222, 0.126, 0.011),
            L("AMOUNT DUE: $8.67", 0.511, 0.205, 0.141, 0.015),
            L("Notes from the Pharmacy", 0.210, 0.188, 0.293, 0.019),
            L("Vaccines you may be due for:", 0.348, 0.164, 0.253, 0.019, 0.5),
            L("-Flu", 0.348, 0.149, 0.034, 0.015),
            L("CVS pharmacy®", 0.351, 0.065, 0.239, 0.026, 0.3),
            L("HERE P", 0.672, 0.065, 0.055, 0.024, 0.3),
            // A neighbouring label, cut off at the right edge of the photo.
            L("NE", 0.882, 0.884, 0.080, 0.052),
            L("Sample, Al", 0.875, 0.842, 0.125, 0.036),
            L("Receipt & Re", 0.853, 0.453, 0.144, 0.020),
            L("RETAIL PRICE:$9.99", 0.859, 0.246, 0.138, 0.011),
        ]
    }

    @Test func parsesRealLayout() {
        let r = CVSLabelParser().parse(lines: lines)
        #expect(r[.storeCode] == "NE")
        #expect(r[.binSlot] == "59")
        #expect(r[.readyFill] == "true")
        #expect(r[.patientName] == "Sample, Alex J")
        #expect(r[.patientStreet] == "12 Example St")
        #expect(r[.patientCity] == "Boston")
        #expect(r[.patientZip] == "02110")
        #expect(r[.drugName] == "IC LISINOPRIL")
        #expect(r[.strengthForm] == "10 MG TABLET")
        #expect(r[.commonBrands] == "Zestril")
        #expect(r[.directions] == "Take 1 tablet by mouth every day")
        #expect(r[.scheduleMorning] == "SEE DIRECTIONS")
        #expect(r[.scheduleBedtime] == "SEE DIRECTIONS")
        #expect(r.draft.list(.importantInfo) == [
            "This medication may cause dizziness.",
            "May take with or without food. Swallow. Do not chew.",
        ])
        #expect(r[.pharmacyName] == "CVS Pharmacy")
        #expect(r[.pharmacyStreet] == "100 Main St, E Bos")
        #expect(r[.pharmacyCity] == "Boston")
        #expect(r[.rxNumber] == "1234567")
        #expect(r[.fillNumber] == "00")
        #expect(r[.refillFlag] == "true")
        #expect(r[.insurancePlanName] == "CAREMARK")
        #expect(r[.bin] == "004336")
        #expect(r[.tp] == "12345")
        #expect(r[.authNumber] == "111222333444555666")
        #expect(r[.retailPrice] == "1311.99")
        #expect(r[.refillsRemaining] == "11")
        #expect(r[.daysSupply] == "30")
        #expect(r[.amountDue] == "8.67")
        #expect(r[.pharmacyNotes] == "Vaccines you may be due for:\n-Flu")
    }

    /// Notes stop at the box: the logo and "OPEN HERE ▶" below it are never included, even when read
    /// as one line or when the logo isn't read at all.
    @Test(arguments: [["OPEN HERE ▶"], ["OPEN HERE D"], ["0PEN", "HERE >"], ["Open here"]])
    func notesExcludeFooter(footer: [String]) {
        var ls = [
            L("AMOUNT DUE: $8.67", 0.511, 0.205, 0.141, 0.015),
            L("Notes from the Pharmacy", 0.210, 0.188, 0.293, 0.019),
            L("Vaccines you may be due for:", 0.348, 0.164, 0.253, 0.019),
            L("-Flu", 0.348, 0.149, 0.034, 0.015),
        ]
        for (i, f) in footer.enumerated() {
            ls.append(L(f, 0.70, 0.050 - Double(i) * 0.013, 0.06, 0.012, 0.5))
        }
        let r = CVSLabelParser().parse(lines: ls)
        #expect(r[.pharmacyNotes] == "Vaccines you may be due for:\n-Flu")
    }

    @Test func emptyNotesBoxStaysEmpty() {
        let r = CVSLabelParser().parse(lines: [
            L("AMOUNT DUE: $8.67", 0.511, 0.205, 0.141, 0.015),
            L("Notes from the Pharmacy", 0.210, 0.188, 0.293, 0.019),
            // Nothing inside the box; only the footer far below it.
            L("Something printed below the box", 0.30, 0.060, 0.25, 0.015, 0.3),
            L("OPEN HERE", 0.70, 0.045, 0.06, 0.012),
        ])
        #expect(r[.pharmacyNotes] == nil)
    }

    @Test func letterBinSlot() {
        let r = CVSLabelParser().parse(lines: [L("NE", 0.2, 0.88, 0.09, 0.045), L("REF", 0.31, 0.885, 0.08, 0.028),
                                               L("Promised: 9/15/26, 8:00 PM", 0.43, 0.93, 0.25, 0.026)])
        #expect(r[.binSlot] == "REF")
    }

    @Test func mergePrefersAgreementThenConfidence() {
        func field(_ v: String, _ c: Double) -> ParsedField { ParsedField(value: v, confidence: c, boxes: []) }
        var a = ParseResult(), b = ParseResult(), c = ParseResult()
        a.fields[.tp] = field("93125", 0.9)
        b.fields[.tp] = field("12345", 0.6)
        c.fields[.tp] = field("12345", 0.6)
        a.fields[.importantInfo] = field("One", 1)
        b.fields[.importantInfo] = field("One\nTwo\nThree", 1)
        a.fields[.drugName] = field("IC LISINOPRIL", 0.5)
        let m = CVSLabelParser.merge([a, b, c])
        #expect(m[.tp] == "12345")               // two photos agree
        #expect(m[.importantInfo] == "One\nTwo\nThree")   // most complete list
        #expect(m[.drugName] == "IC LISINOPRIL")   // only one photo saw it
    }

    @Test func pagedLinesAreParsedPerPageAndMerged() {
        let top = [L("NDC: 00093-1048-01", 0.1, 0.8, 0.4, 0.03), L("QTY: 30 EA", 0.1, 0.75, 0.3, 0.03)]
            .map { var l = $0; l.page = 0; return l }
        let bottom = [L("AMOUNT DUE: $4.00", 0.1, 0.3, 0.4, 0.03)]
            .map { var l = $0; l.page = 1; return l }
        let r = CVSLabelParser().parse(pagedLines: top + bottom)
        #expect(r[.ndc] == "00093-1048-01")
        #expect(r[.amountDue] == "4.00")
    }
}

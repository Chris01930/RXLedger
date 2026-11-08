import Foundation
import SwiftData
import Testing
import UIKit
@testable import RxLedger

private final class Token {}

@Suite("Add photo for missing fields")
@MainActor
struct SupplementTests {
    @Test func fillBlanksNeverOverwrites() {
        var draft = FillDraft()
        draft[.drugName] = "TYPED BY HAND"
        draft[.amountDue] = "9.99"
        var parse = ParseResult()
        parse.fields[.drugName] = ParsedField(value: "IC METFORMIN HCL", confidence: 1, boxes: [])
        parse.fields[.amountDue] = ParsedField(value: "0.00", confidence: 1, boxes: [])
        parse.fields[.ndc] = ParsedField(value: "00093-1048-01", confidence: 1, boxes: [])
        parse.fields[.refillFlag] = ParsedField(value: "true", confidence: 1, boxes: [])

        let filled = draft.fillBlanks(from: parse)
        #expect(filled == [.refillFlag, .ndc])          // form order
        #expect(draft[.drugName] == "TYPED BY HAND")
        #expect(draft[.amountDue] == "9.99")
        #expect(draft[.ndc] == "00093-1048-01")
        #expect(draft.bool(.refillFlag))
    }

    @Test func supplementStacksPhotoAndTagsPages() async throws {
        // Existing record: a small image and the top of the label as OCR text.
        let existingImage = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        let topText = try loadFixture("cvs_label_clean").components(separatedBy: "\n").prefix(12).joined(separator: "\n")
        let existingLines = OCRLine.fromPlainText(topText)

        let url = try #require(Bundle(for: Token.self).url(forResource: "rendered_label_upside_down", withExtension: "png"))
        let photo = try #require(UIImage(contentsOfFile: url.path))
        let r = try await OCRService().supplement(existingImage: existingImage, existingLines: existingLines, with: photo)

        #expect(Set(r.lines.compactMap(\.page)) == [0, 1])
        #expect(r.lines.filter { $0.page == 0 }.count == existingLines.count)
        #expect(r.parse[.ndc] == "00093-1048-01")
        #expect(r.parse[.amountDue] == "0.00")
        // New photo sits below the existing image in the stack.
        let ndcBox = try #require(r.parse.boundingBox(for: .ndc))
        #expect(ndcBox.maxY < 1.0 && r.image.size.height > existingImage.size.height)
        #expect(r.crops[.ndc] != nil)
        #expect(r.imageData != nil)
        // The earlier text is re-parsed for comparison.
        #expect(r.previous?[.drugName] == "IC METFORMIN HCL")
    }

    @Test func ocrFilledFieldsAreNotManualEdits() throws {
        let config = ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: PersistenceController.schema, configurations: [config]))
        let repo = FillRepository(context: context)
        var partial = SampleData.metforminDraft
        partial[.ndc] = ""
        let fill = try repo.create(from: partial, source: .scan, ocr: nil)
        #expect(!fill.wasEditedAfterScan)

        var completed = partial
        completed[.ndc] = "00093-1048-01"
        let payload = OCRPayload(rawText: "a\nb", lines: [OCRLine(text: "a", confidence: 1, boundingBox: .zero, page: 0),
                                                          OCRLine(text: "b", confidence: 1, boundingBox: .zero, page: 1)],
                                 confidence: 0.9, imageData: Data([1, 2, 3]))
        try repo.update(fill, with: completed, ocr: payload, ocrFilledKeys: [.ndc])
        #expect(fill.ndc == "00093-1048-01")
        #expect(!fill.wasEditedAfterScan)
        #expect(fill.ocrLines.count == 2)
        #expect(fill.imageData == Data([1, 2, 3]))

        // A genuine manual change still counts.
        var typed = completed
        typed[.amountDue] = "1.00"
        try repo.update(fill, with: typed)
        #expect(fill.wasEditedAfterScan)
    }
}

@Suite("Differences between photos")
struct FieldConflictTests {
    private func parse(_ values: [FieldKey: (String, Double)]) -> ParseResult {
        var r = ParseResult()
        for (k, v) in values { r.fields[k] = ParsedField(value: v.0, confidence: v.1, boxes: []) }
        return r
    }

    @Test func detectsDifferencesAndSources() {
        var draft = FillDraft()
        draft[.tp] = "93125"          // from the earlier scan, low confidence
        draft[.amountDue] = "8.67"    // typed over the scan this session
        draft[.ndc] = "00093-1048-01" // same value, different formatting below
        draft[.retailPrice] = "47.09" // agrees
        draft[.importantInfo] = "Take with food\nAvoid alcohol"
        var baseline = draft
        baseline[.amountDue] = "8.57"

        let previous = parse([.tp: ("93125", 0.3), .amountDue: ("8.57", 1), .ndc: ("00093-1048-01", 1), .retailPrice: ("47.09", 1)])
        // NDC printed 4-4-2 normalizes to the same code; "$47.09" is the same amount; a partial bullet list isn't a disagreement.
        let new = parse([.tp: ("33125", 1), .amountDue: ("8.57", 1), .ndc: ("0093-1048-01", 1),
                         .retailPrice: ("$47.09", 0.5), .importantInfo: ("Avoid alcohol", 1)])

        let conflicts = FieldConflict.detect(draft: draft, baseline: baseline, previous: previous, new: new)
        #expect(conflicts.map(\.key) == [.amountDue, .tp].sorted { FieldKey.allCases.firstIndex(of: $0)! < FieldKey.allCases.firstIndex(of: $1)! })

        let tp = conflicts.first { $0.key == .tp }!
        #expect(tp.currentSource == .scan(confidence: 0.3))
        #expect(tp.newValue == "33125")
        #expect(tp.prefersNew)                         // clearly more confident

        let amount = conflicts.first { $0.key == .amountDue }!
        #expect(amount.currentSource == .edited)
        #expect(!amount.prefersNew)                    // never override a typed value by default
    }

    @Test func manualEntryHasNoEarlierScan() {
        var draft = FillDraft()
        draft[.patientName] = "Sample, Alex"
        let conflicts = FieldConflict.detect(draft: draft, baseline: draft, previous: nil,
                                             new: parse([.patientName: ("Sample, Alex J", 1)]))
        #expect(conflicts.count == 1)
        #expect(conflicts[0].currentSource == .entered)
        #expect(!conflicts[0].prefersNew)
    }

    @Test func equalConfidenceKeepsCurrent() {
        var draft = FillDraft()
        draft[.gr] = "UNITEDRX"
        let conflicts = FieldConflict.detect(draft: draft, baseline: draft, previous: parse([.gr: ("UNITEDRX", 1)]),
                                             new: parse([.gr: ("UNITEDAX", 1)]))
        #expect(conflicts.count == 1)
        #expect(!conflicts[0].prefersNew)
    }
}

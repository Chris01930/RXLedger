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

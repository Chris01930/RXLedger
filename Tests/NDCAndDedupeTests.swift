import Foundation
import SwiftData
import Testing
@testable import RxLedger

@Suite("NDC normalization")
struct NDCTests {
    @Test(arguments: [
        ("00093-1048-01", "00093104801"),   // 5-4-2
        ("0093-1048-01", "00093104801"),    // 4-4-2
        ("00093-148-01", "00093014801"),    // 5-3-2
        ("00093-1048-1", "00093104801"),    // 5-4-1
        ("00093104801", "00093104801"),     // bare 11
        ("00093 1048 01", "00093104801"),   // spaces
    ])
    func normalizes(input: String, expected: String) {
        #expect(NDC.normalize(input) == expected)
    }

    @Test(arguments: ["0093104801", "000-1048-01", "abcde-1048-01", "", "00093-10480-1"])
    func rejects(input: String) {
        #expect(NDC.normalize(input) == nil)
    }

    @Test func formats() {
        #expect(NDC.format542("00093104801") == "00093-1048-01")
        #expect(NDC.format542("123") == nil)
        #expect(NDC.isValid542("00093-1048-01"))
        #expect(!NDC.isValid542("0093-1048-01"))
    }
}

@Suite("Dedupe")
@MainActor
struct DedupeTests {
    @Test func primaryKey() {
        let date = LabelFormat.parseDate("6/23/26")
        #expect(DedupeService.key(rxNumber: "2581363", fillNumber: "01", ndc: "00093-1048-01", dateFilled: date) == "2581363-01")
        #expect(DedupeService.key(rxNumber: "2581363", fillNumber: "1", ndc: nil, dateFilled: nil) == "2581363-01")
    }

    @Test func fallbackKey() {
        let date = LabelFormat.parseDate("6/23/26")
        #expect(DedupeService.key(rxNumber: nil, fillNumber: nil, ndc: "0093-1048-01", dateFilled: date) == "00093104801-2026-06-23")
        #expect(DedupeService.key(rxNumber: "2581363", fillNumber: nil, ndc: "00093-1048-01", dateFilled: date) == "00093104801-2026-06-23")
        #expect(DedupeService.key(rxNumber: nil, fillNumber: nil, ndc: nil, dateFilled: date) == nil)
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: PersistenceController.schema, configurations: [config])
        return ModelContext(container)
    }

    @Test func findsDuplicateAndLinksRelatedRecords() throws {
        let context = try makeContext()
        let repo = FillRepository(context: context)
        let draft = SampleData.metforminDraft

        let first = try repo.create(from: draft, source: .scan, ocr: nil)
        #expect(first.dedupeKey == "2581363-01")
        #expect(DedupeService.findExisting(key: DedupeService.key(for: draft), in: context)?.id == first.id)
        // Editing the same fill isn't a conflict with itself.
        #expect(DedupeService.findExisting(key: first.dedupeKey, in: context, excluding: first.id) == nil)

        // A second fill of the same Rx is not a duplicate and shares the medication, pharmacy, etc.
        var next = draft
        next[.fillNumber] = "02"
        next[.dateFilled] = "7/23/26"
        let second = try repo.create(from: next, source: .manual, ocr: nil)
        #expect(DedupeService.findExisting(key: "2581363-02", in: context)?.id == second.id)
        #expect(first.medication != nil && first.medication?.id == second.medication?.id)
        #expect(first.pharmacy?.id == second.pharmacy?.id)
        #expect(first.insurance?.id == second.insurance?.id)
        #expect(first.prescriber?.id == second.prescriber?.id)
        #expect(first.patient?.id == second.patient?.id)
        #expect(try context.fetchCount(FetchDescriptor<Medication>()) == 1)
        #expect(second.medication?.lastFill?.id == second.id)
        #expect(second.medication?.totalCopayPaid == 0)
    }

    @Test func replaceKeepsCreatedAt() throws {
        let context = try makeContext()
        let repo = FillRepository(context: context)
        let original = try repo.create(from: SampleData.metforminDraft, source: .manual, ocr: nil)
        let createdAt = original.createdAt

        var rescanned = SampleData.metforminDraft
        rescanned[.amountDue] = "1.25"
        let replaced = try repo.replace(original, with: rescanned, source: .scan,
                                        ocr: OCRPayload(rawText: "x", lines: [], confidence: 0.9))
        #expect(replaced.id == original.id)
        #expect(replaced.createdAt == createdAt)
        #expect(replaced.source == .scan)
        #expect(replaced.amountDue == Decimal(string: "1.25"))
        #expect(try context.fetchCount(FetchDescriptor<Fill>()) == 1)
    }

    @Test func unkeyedFillsNeverCollide() throws {
        let context = try makeContext()
        let repo = FillRepository(context: context)
        var draft = FillDraft()
        draft[.drugName] = "VITAMIN D"
        let a = try repo.create(from: draft, source: .manual, ocr: nil)
        let b = try repo.create(from: draft, source: .manual, ocr: nil)
        #expect(a.dedupeKey != b.dedupeKey)
        #expect(DedupeService.findExisting(key: a.dedupeKey, in: context) == nil)
        #expect(DedupeService.usesFallback(draft))
    }

    @Test func draftRoundTrip() throws {
        let context = try makeContext()
        let fill = try FillRepository(context: context).create(from: SampleData.metforminDraft, source: .scan, ocr: nil)
        let roundTripped = fill.draft()
        #expect(roundTripped.changedKeys(comparedTo: SampleData.metforminDraft).isEmpty)
    }
}

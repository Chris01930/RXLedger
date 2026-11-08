import Foundation
import SwiftData
import Testing
@testable import RxLedger

@Suite("Export and import")
@MainActor
struct ExportTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: PersistenceController.schema, configurations: [config]))
    }

    @Test func backupRoundTrip() throws {
        let source = try makeContext()
        SampleData.seedIfEmpty(source)
        let originalCount = try source.fetchCount(FetchDescriptor<Fill>())
        let data = try ExportService.backupData(context: source)

        let target = try makeContext()
        let summary = try ExportService.importBackup(data, context: target)
        #expect(summary.imported == originalCount)
        #expect(summary.skippedDuplicates == 0)

        let restored = try target.fetch(FetchDescriptor<Fill>())
        let originals = try source.fetch(FetchDescriptor<Fill>())
        for original in originals {
            let copy = try #require(restored.first { $0.id == original.id })
            #expect(copy.draft() == original.draft())
            #expect(copy.createdAt == original.createdAt || abs(copy.createdAt.timeIntervalSince(original.createdAt)) < 1)
            #expect(copy.source == original.source)
            #expect(copy.wasEditedAfterScan == original.wasEditedAfterScan)
        }
        // Inactive medication state survives.
        let inactive = try target.fetch(FetchDescriptor<Medication>()).filter { !$0.isActive }
        #expect(inactive.count == 1)

        // Importing again skips everything.
        let again = try ExportService.importBackup(data, context: target)
        #expect(again.imported == 0)
        #expect(again.skippedDuplicates == originalCount)
    }

    @Test func csvEscapesAndHasAllColumns() throws {
        let context = try makeContext()
        SampleData.seedIfEmpty(context)
        let csv = ExportService.csv(for: try context.fetch(FetchDescriptor<Fill>()))
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 5)
        #expect(lines[0].split(separator: ",").count == ExportService.csvMetadataColumns.count + FieldKey.allCases.count)
        #expect(csv.contains("\"Sample, Alex J\""))
        #expect(ExportService.escape("a \"b\"") == "\"a \"\"b\"\"\"")
    }

    @Test func rejectsNonBackup() throws {
        let context = try makeContext()
        #expect(throws: ExportService.ImportError.self) {
            try ExportService.importBackup(Data("{}".utf8), context: context)
        }
    }
}

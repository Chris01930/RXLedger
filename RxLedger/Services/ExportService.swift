import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// CSV export, JSON backup and JSON restore.
@MainActor
enum ExportService {
    // MARK: CSV

    static let csvMetadataColumns = ["id", "source", "created_at", "updated_at", "edited_after_scan", "ocr_confidence", "dedupe_key", "ndc_11"]

    static func csv(for fills: [Fill]) -> String {
        let header = csvMetadataColumns + FieldKey.allCases.map(\.rawValue)
        var lines = [header.map(escape).joined(separator: ",")]
        let iso = ISO8601DateFormatter()
        for fill in fills.sorted(by: { $0.sortDate > $1.sortDate }) {
            var row = [
                fill.id.uuidString,
                fill.source.rawValue,
                iso.string(from: fill.createdAt),
                iso.string(from: fill.updatedAt),
                fill.wasEditedAfterScan ? "true" : "false",
                fill.ocrConfidence.map { String(format: "%.3f", $0) } ?? "",
                DedupeService.isUnkeyed(fill.dedupeKey) ? "" : fill.dedupeKey,
                fill.ndcNormalized ?? "",
            ]
            for key in FieldKey.allCases {
                let value = fill.stringValue(for: key)
                row.append(key == .importantInfo ? value.replacingOccurrences(of: "\n", with: "; ") : value)
            }
            lines.append(row.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: JSON backup

    struct Backup: Codable {
        var format = "RxLedger-backup"
        var version = 1
        var exportedAt: Date
        var fills: [FillRecord]
        var medications: [MedicationRecord]
    }

    struct FillRecord: Codable {
        var id: UUID
        var source: DataSource
        var createdAt: Date
        var updatedAt: Date
        var wasEditedAfterScan: Bool
        var ocrConfidence: Double?
        var fields: FillDraft
        var rawOCRText: String?
        var ocrLines: [OCRLine]?
        /// JPEG, base64-encoded by JSONEncoder.
        var image: Data?
    }

    struct MedicationRecord: Codable {
        var matchKey: String
        var isActive: Bool
    }

    static func backupData(context: ModelContext) throws -> Data {
        let fills = try context.fetch(FetchDescriptor<Fill>(sortBy: [SortDescriptor(\.createdAt)]))
        let meds = try context.fetch(FetchDescriptor<Medication>())
        let backup = Backup(
            exportedAt: Date(),
            fills: fills.map { f in
                FillRecord(id: f.id, source: f.source, createdAt: f.createdAt, updatedAt: f.updatedAt,
                           wasEditedAfterScan: f.wasEditedAfterScan, ocrConfidence: f.ocrConfidence,
                           fields: f.draft(), rawOCRText: f.rawOCRText,
                           ocrLines: f.ocrLines.isEmpty ? nil : f.ocrLines, image: f.imageData)
            },
            medications: meds.map { MedicationRecord(matchKey: $0.matchKey, isActive: $0.isActive) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    struct ImportSummary {
        var imported = 0
        var skippedDuplicates = 0

        var message: String {
            var parts = ["Imported \(imported) fill\(imported == 1 ? "" : "s")."]
            if skippedDuplicates > 0 {
                parts.append("Skipped \(skippedDuplicates) already recorded.")
            }
            return parts.joined(separator: " ")
        }
    }

    enum ImportError: LocalizedError {
        case notABackup
        var errorDescription: String? { "This file isn't an RxLedger backup." }
    }

    /// Restores a backup. Existing fills (same id or same dedupe key) are kept and the backup copy skipped.
    static func importBackup(_ data: Data, context: ModelContext) throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(Backup.self, from: data), backup.format == "RxLedger-backup" else {
            throw ImportError.notABackup
        }
        let repo = FillRepository(context: context)
        var summary = ImportSummary()
        let existingIDs = Set(try context.fetch(FetchDescriptor<Fill>()).map(\.id))

        for record in backup.fills {
            if existingIDs.contains(record.id)
                || DedupeService.findExisting(key: DedupeService.key(for: record.fields), in: context) != nil {
                summary.skippedDuplicates += 1
                continue
            }
            let ocr: OCRPayload? = (record.rawOCRText != nil || record.image != nil)
                ? OCRPayload(rawText: record.rawOCRText ?? "", lines: record.ocrLines ?? [],
                             confidence: record.ocrConfidence, imageData: record.image)
                : nil
            let fill = try repo.create(from: record.fields, source: record.source, ocr: ocr,
                                       wasEditedAfterScan: record.wasEditedAfterScan)
            if ocr?.rawText.isEmpty == true { fill.rawOCRText = nil }
            if DedupeService.isUnkeyed(fill.dedupeKey) { fill.dedupeKey = "unkeyed-\(record.id.uuidString)" }
            fill.id = record.id
            fill.createdAt = record.createdAt
            fill.updatedAt = record.updatedAt
            summary.imported += 1
        }

        let meds = try context.fetch(FetchDescriptor<Medication>())
        for record in backup.medications {
            meds.first { $0.matchKey == record.matchKey }?.isActive = record.isActive
        }
        try context.save()
        return summary
    }

    static func timestampedName(_ base: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "\(base)-\(f.string(from: Date()))"
    }
}

/// Wraps export data for `.fileExporter`.
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }

    var data: Data
    var contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

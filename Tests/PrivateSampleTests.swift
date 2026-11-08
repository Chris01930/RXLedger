import Foundation
import Testing
import UIKit
@testable import RxLedger

/// Runs the full OCR pipeline on real label photos kept in `Tests/Private/` (git-ignored, never committed).
/// For each image, an optional `<name>.expected.json` ({"fieldKey": "value", ...}) is compared field by field.
/// Skipped automatically when the folder is empty (e.g. on another machine or CI).
@Suite("Private samples")
struct PrivateSampleTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Private")

    static var images: [URL] {
        let exts = ["heic", "jpg", "jpeg", "png"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    @Test(.enabled(if: !images.isEmpty))
    func realLabels() async throws {
        for url in Self.images {
            let image = try #require(UIImage(contentsOfFile: url.path), "Unreadable \(url.lastPathComponent)")
            let result = try await OCRService().process(image)
            let name = url.deletingPathExtension().lastPathComponent

            do {
                var dump = "===== \(name) =====\n--- OCR lines ---\n"
                for l in result.lines {
                    dump += String(format: "[%.3f %.3f %.3f %.3f] %.2f  ", l.boundingBox.minX, l.boundingBox.minY,
                                   l.boundingBox.width, l.boundingBox.height, l.confidence) + l.text + "\n"
                }
                dump += "--- Parsed ---\n"
                for key in FieldKey.allCases {
                    dump += "\(key.rawValue): \(result.parse[key] ?? "∅")\n"
                }
                try? dump.write(to: Self.folder.appendingPathComponent("\(name).dump.txt"), atomically: true, encoding: .utf8)
            }

            let expectedURL = Self.folder.appendingPathComponent("\(name).expected.json")
            guard let data = try? Data(contentsOf: expectedURL),
                  let expected = try? JSONDecoder().decode([String: String].self, from: data) else { continue }
            var mismatches: [String] = []
            for (k, v) in expected.sorted(by: { $0.key < $1.key }) {
                guard let key = FieldKey(rawValue: k) else { continue }
                let got = result.parse[key] ?? ""
                if got != v { mismatches.append("\(k): expected '\(v)' got '\(got)'") }
            }
            #expect(mismatches.isEmpty, "\(name):\n\(mismatches.joined(separator: "\n"))")
        }
    }

    /// Simulates close-ups: each photo split into overlapping top and bottom halves, read and merged.
    @Test(.enabled(if: !images.isEmpty))
    func closeUpHalves() async throws {
        for url in Self.images {
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent("\(name).expected.json")),
                  let expected = try? JSONDecoder().decode([String: String].self, from: data),
                  let full = UIImage(contentsOfFile: url.path) else { continue }
            let upright = ImageProcessing.normalizedOrientation(full)
            let cg = try #require(upright.cgImage)
            let w = cg.width, h = cg.height
            // The label runs top-to-bottom in these photos: split into overlapping halves.
            let top = try #require(cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: Int(Double(h) * 0.58))))
            let bottom = try #require(cg.cropping(to: CGRect(x: 0, y: Int(Double(h) * 0.42), width: w, height: h - Int(Double(h) * 0.42))))
            let result = try await OCRService().processCloseUps([UIImage(cgImage: top), UIImage(cgImage: bottom)])
            let dump = result.lines.map { l in
                String(format: "p%d [%.3f %.3f %.3f %.3f] %.2f  ", l.page ?? -1, l.boundingBox.minX, l.boundingBox.minY,
                       l.boundingBox.width, l.boundingBox.height, l.confidence) + l.text
            }.joined(separator: "\n")
            try? dump.write(to: Self.folder.appendingPathComponent("\(name).closeups.dump.txt"), atomically: true, encoding: .utf8)
            var mismatches: [String] = []
            for (k, v) in expected.sorted(by: { $0.key < $1.key }) {
                guard let key = FieldKey(rawValue: k) else { continue }
                if (result.parse[key] ?? "") != v { mismatches.append("\(k): expected '\(v)' got '\(result.parse[key] ?? "")'") }
            }
            // Halves of one photo add no resolution (unlike real close-ups) and cut through lines at the seam,
            // so this is an accuracy floor rather than an exact match.
            let accuracy = 1 - Double(mismatches.count) / Double(expected.count)
            #expect(accuracy >= 0.9, "\(name) close-ups \(Int(accuracy * 100))%:\n\(mismatches.joined(separator: "\n"))")
            if !mismatches.isEmpty { print("\(name) close-up misses:\n" + mismatches.joined(separator: "\n")) }
            #expect(Set(result.lines.compactMap(\.page)) == [0, 1])
        }
    }

    /// Writes context crops from the add-photo path so their outlines can be checked by eye.
    @Test(.enabled(if: !images.isEmpty))
    func contextCropsForReview() async throws {
        let url = try #require(Self.images.first)
        let photo = try #require(UIImage(contentsOfFile: url.path))
        let r = try await OCRService().supplement(existingImage: nil, existingLines: [], with: photo)
        // Written to a subfolder so these crops are never picked up as label photos.
        let output = Self.folder.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for key in [FieldKey.tp, .daysSupply, .ndc, .patientName] {
            let crop = try #require(r.contextCrops[key], "no context crop for \(key)")
            try crop.jpegData(compressionQuality: 0.8)?.write(to: output.appendingPathComponent("context-\(key.rawValue).jpg"))
        }
    }

    /// Partial close-ups / screenshots in `Tests/Private/CloseUps/`, each with `<name>.expected.json`.
    /// Exercises the add-photo path (`supplement`) on images showing only a few fields.
    static var closeUps: [URL] {
        let dir = folder.appendingPathComponent("CloseUps")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    @Test(.enabled(if: !closeUps.isEmpty))
    func partialCloseUps() async throws {
        for url in Self.closeUps {
            let name = url.deletingPathExtension().lastPathComponent
            let image = try #require(UIImage(contentsOfFile: url.path))
            let r = try await OCRService().supplement(existingImage: nil, existingLines: [], with: image)
            var dump = "--- lines ---\n" + r.lines.map { l in
                String(format: "[%.3f %.3f %.3f %.3f] %.2f  ", l.boundingBox.minX, l.boundingBox.minY,
                       l.boundingBox.width, l.boundingBox.height, l.confidence) + l.text
            }.joined(separator: "\n")
            dump += "\n--- parsed ---\n" + r.parse.fields.keys.sorted { $0.rawValue < $1.rawValue }
                .map { "\($0.rawValue): \(r.parse[$0] ?? "")" }.joined(separator: "\n")
            try? dump.write(to: url.deletingPathExtension().appendingPathExtension("dump.txt"), atomically: true, encoding: .utf8)

            let expectedURL = url.deletingPathExtension().appendingPathExtension("expected.json")
            guard let data = try? Data(contentsOf: expectedURL),
                  let expected = try? JSONDecoder().decode([String: String].self, from: data) else { continue }
            for (k, v) in expected {
                guard let key = FieldKey(rawValue: k) else { continue }
                #expect(r.parse[key] == v, "\(name): \(k)")
            }
        }
    }
}

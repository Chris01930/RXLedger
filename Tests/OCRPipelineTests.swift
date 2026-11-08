import Testing
import UIKit
@testable import RxLedger

private final class Token {}

/// End-to-end: Vision OCR + parser on a rendered (synthetic) label image stored upside down.
@Suite("OCR pipeline")
struct OCRPipelineTests {
    @Test func upsideDownRenderedLabel() async throws {
        let url = try #require(Bundle(for: Token.self).url(forResource: "rendered_label_upside_down", withExtension: "png"))
        let image = try #require(UIImage(contentsOfFile: url.path))
        let result = try await OCRService().process(image)
        let p = result.parse

        let expected = CVSLabelParser().parse(text: try loadFixture("cvs_label_clean"))
        var mismatches: [String] = []
        for key in FieldKey.allCases where expected[key] != p[key] {
            mismatches.append("\(key.rawValue): expected \(expected[key] ?? "nil") got \(p[key] ?? "nil")")
        }
        if !mismatches.isEmpty {
            print("OCR LINES:\n" + result.rawText)
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
        #expect(result.imageData != nil)
        #expect(!result.annotations.crops.isEmpty)
    }
}

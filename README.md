# RxLedger

A private, on-device iOS app that scans CVS Pharmacy prescription labels, extracts every field with Apple Vision OCR, and keeps a local history of fills and medications.

- **No networking.** OCR, parsing and storage all happen on the iPhone.
- **iOS 17+**, SwiftUI + SwiftData, iPhone-first (adaptive on iPad).
- Bundle ID `com.chrisnewell.rxledger`.

## Build & run

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen      # once
xcodegen generate          # after adding/removing files
open RxLedger.xcodeproj
```

`RxLedger.xcodeproj` is committed, so XcodeGen is only needed when the file list changes.

To run on a device or ship to TestFlight, select your team under **Signing & Capabilities** (or add `DEVELOPMENT_TEAM: <TEAMID>` to `project.yml` under `settings.base`), then **Product → Archive**.

### Tests

```sh
xcodebuild -project RxLedger.xcodeproj -scheme RxLedger \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Suites (Swift Testing):

| Suite | Covers |
|---|---|
| `CVSLabelParser` | Every field from `Tests/Fixtures/*.txt`, O/0 · l/1 · S/5 repair, wrapped lines, SEE DIRECTIONS, geometry-based rows |
| `NDC normalization` | 5-4-2 / 4-4-2 / 5-3-2 / 5-4-1 → 11 digits, rejection of bad input |
| `Dedupe` | Rx+fill key, NDC+date fallback, replace keeps `createdAt`, related-record linking |
| `Export and import` | JSON backup round trip, re-import skips duplicates, CSV escaping |
| `OCR pipeline` | Vision + parser end-to-end on a rendered, upside-down label image |
| `Real CVS layout` | Real CVS layout as positioned OCR lines (fictional values): vertical schedule column, two-column receipt, neighbouring label, garbled anchors; merging of close-ups |
| `Private samples` | Your own label photos in `Tests/Private/` (git-ignored); skipped when the folder is empty |

### Private real-label samples

Put real label photos (`.heic`/`.jpg`/`.png`) in `Tests/Private/`. The folder is git-ignored, so they never leave your Mac. For each photo the test suite:

- writes `<name>.dump.txt`: every OCR line with its position, plus every parsed field;
- compares against `<name>.expected.json` (`{"fieldKey": "value"}`) if that file exists;
- also splits each photo into overlapping halves to exercise the close-up merge, which must get at least 90% of fields right.

Use the dump to see exactly what Vision read when a field comes out wrong.

Partial close-ups or screenshots go in `Tests/Private/CloseUps/`, each with a `<name>.expected.json` listing only the fields that photo should yield. They run through the add-photo path, and a dump is written next to each.

### Adding real fixtures

Put OCR text in `Tests/Fixtures/<name>.txt`, one OCR line per text line, in reading order. You can copy it from **Fill detail → Raw OCR text** after a scan. Leading spaces are treated as column positions, which matters for the schedule boxes. Then add a test that calls `loadFixture("<name>")`. Remove personal details before committing real labels.

### Debug launch arguments

Set these in the scheme's *Arguments Passed On Launch*. They only work in Debug builds:

| Argument | Effect |
|---|---|
| `-inMemoryStore` | Use a throwaway in-memory store |
| `-seedSampleData` | Insert fictional sample fills if the store is empty |
| `-skipAppLock` | Start unlocked with the lock disabled |
| `-scanImagePath /path/img.png` | Run the full OCR pipeline on a file at launch (the simulator has no camera) |
| `-startTab medications\|capture\|settings` | Open on a given tab |
| `-openFirstFill` | Push the first fill's detail screen |
| `-previewConflictSheet` | Show the "Review Differences" sheet with sample data |

## Project layout

```
RxLedger/
  App/          RxLedgerApp (AppState), RootView, AppLockManager (+ lock screen)
  Models/       Fill, Medication/Pharmacy/Prescriber/InsurancePlan/Patient,
                FieldKey (every label field), FillDraft (editable snapshot), OCRLine, SampleData
  Services/     CVSLabelParser, OCRService, ImageProcessing, DedupeService, NDC,
                FillRepository, PersistenceController, ExportService, LabelFormat
  Views/        Fills, Medications, Capture (camera, picker, review queue),
                Editor (shared form), Detail (reconstructed label), Settings, Shared
Tests/          Swift Testing suites + Fixtures/
```

How data flows:

1. **Capture**: the document camera or PhotosPicker produces `UIImage`s.
2. **OCRService** fixes EXIF orientation, converts to grayscale, runs Vision, and rotates until the text is upright. It then re-reads the schedule strip if needed.
3. **CVSLabelParser** turns the lines into a `ParseResult`: a `FillDraft` plus per-field confidence and bounding boxes.
4. **FillEditorView** reviews or edits the draft, validates it, and checks `DedupeService`.
5. **FillRepository** saves the `Fill` and links the de-duplicated related records.

Manual entry, scan review, edit and re-parse all use the same `FillEditorView`.

See [DECISIONS.md](DECISIONS.md) for assumptions and trade-offs.

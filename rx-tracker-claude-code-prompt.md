# Claude Code Prompt — "RxLedger" iOS Prescription Tracker

Build a native iOS app called **RxLedger** that scans CVS Pharmacy prescription labels, extracts every field via on-device OCR, and keeps a local history of all my prescription fills and medications. Use the stack and requirements below. Ask me clarifying questions only if something is truly blocking; otherwise make reasonable choices and note them in a `DECISIONS.md`.

## Stack

- Swift 5.10+, SwiftUI, SwiftData, iOS 17.0+ minimum, iPhone-first (iPad OK via adaptive layout).
- Xcode project (not Swift Package only). Bundle ID `com.chrisnewell.rxledger`. Distribution target: personal TestFlight.
- OCR: Apple **Vision** (`VNRecognizeTextRequest`, `.accurate`, language `en-US`, `usesLanguageCorrection = false` so NDCs, Rx numbers and BINs aren't "corrected"). No third-party OCR, no cloud calls — all data stays on device.
- Capture: `VisionKit` `DataScannerViewController` or `VNDocumentCameraViewController` for the camera path, plus `PhotosPicker` for selecting an existing image.
- No networking at all. Optional later: SwiftData + CloudKit sync (leave the model CloudKit-compatible: all properties optional or defaulted, no unique constraints that CloudKit rejects — enforce uniqueness in code).
- Lock the app behind Face ID / Touch ID (`LocalAuthentication`) with a toggle in Settings, on by default.

## The label format

All labels are CVS Pharmacy "bag tag" labels with the same layout. Top to bottom, the printed sections and fields are:

**Header**
- Store code (e.g. `NE`), bin/slot number (e.g. `116`)
- `Promised: M/D/YY, H:MM AM/PM`
- `# Scripts: NN`
- ReadyFill indicator (present/absent)
- Barcode with human-readable digits under it (store a cleaned numeric string)

**Patient band (shaded)**
- Patient name as `Last, First M`
- Street address, City, ST ZIP
- `DOB: M/YY` (CVS prints only month/year)
- `TEL: (NNN) NNN-NNNN`

**Prescription Information**
- Drug line 1 and 2, e.g. `IC METFORMIN HCL` / `500 MG TABLET` (store as `drugName`, `strengthForm`; also store the combined display name)
- `Common brand(s): ...`
- Directions / sig, e.g. `Take 1 tablet by mouth every day`
- Morning / Midday / Evening / Bedtime schedule boxes (either checked quantities or the text `SEE DIRECTIONS`)
- `Important Information` bullet list (store as an array of strings)

**Receipt & Refill Information**
- Pharmacy name, street, city/state/ZIP, `STORE#: NNNN`
- `STORE TEL:`
- `RX: NNNNNNN NN` — the Rx number followed by a two-digit **fill number** (e.g. `2581363 01`), and an `RF`/`RF`-boxed refill flag
- `INSURANCE INFORMATION:` block: plan name, `BIN NNNNNN`, `TP:`, `GR:`, `AUTH#:`
- `RETAIL PRICE: $N.NN`
- `NDC: NNNNN-NNNN-NN` (preserve the 5-4-2 hyphenation; also store an 11-digit normalized form)
- `DAW: N`
- `QTY: NN EA` (store number and unit)
- `CAP: Safety|Non-Safety`
- `MFR PKG: Yes|No`
- `REFILL: N Refills`
- `MFR: ...`
- `PRSCBR: First Last`
- `DAYS SUPPLY: NN`
- `DATE FILLED: M/D/YY`
- `AMOUNT DUE: $N.NN` (this is my copay)

**Notes from the Pharmacy** — free text, usually empty.

**Side sticker** (may or may not be in frame): `DRUG STORAGE TYPE: FAST MOVER`, `DATE:`, `TP:`. Capture if present, don't fail if absent.

Store **every** field above. Also store the raw OCR text (`rawOCRText`) and the recognized lines with bounding boxes so parsing can be re-run later when the parser improves, and keep a downscaled copy of the source image (≤ 1600px long edge, JPEG) attached to the fill record via `@Attribute(.externalStorage)`.

## Data model (SwiftData)

- `Medication` — one per distinct drug. Key on normalized NDC first; fall back to normalized `drugName + strengthForm` if NDC is missing (manual entries). Fields: `ndc`, `displayName`, `drugName`, `strengthForm`, `commonBrands`, `manufacturer`, `isActive` (user toggle), relationship `fills: [Fill]`. Computed: `lastFill`, `totalCopayPaid`, `totalRetail`, `nextRefillEstimate` (lastFill.dateFilled + daysSupply).
- `Fill` — one per scanned/entered label. All label fields listed above, plus:
  - `source: DataSource` enum `{ scan, manual }` — shown as a badge everywhere a fill appears
  - `createdAt`, `updatedAt`, `wasEditedAfterScan: Bool`
  - `ocrConfidence: Double?` (mean of Vision confidences for fields that were parsed)
  - `dedupeKey: String` (see below)
  - relationships: `medication`, `pharmacy`, `prescriber`, `insurance`, `patient`
- `Pharmacy` (store number, name, address, phone), `Prescriber` (name), `InsurancePlan` (plan name, BIN, TP, GR), `Patient` (name, address, DOB month/year, phone). Deduplicate these by their natural key so the pickers in manual entry offer existing values.

## Duplicate prevention

- `dedupeKey` = `rxNumber + "-" + fillNumber` when both exist (that pair uniquely identifies one CVS fill).
- Fallback when the Rx number is missing/unreadable: `normalizedNDC + "-" + dateFilled`.
- On save, if a `Fill` with the same `dedupeKey` exists, do **not** create a new record. Show a sheet: "This fill is already recorded (Rx 2581363, fill 01, 6/23/26)" with options **View existing**, **Replace with this scan** (overwrites fields, keeps the original `createdAt`), or **Cancel**.
- Manual entries use the same rules; if the user leaves Rx number blank, warn that duplicate detection will fall back to NDC + date.

## Scan → review → save flow

1. **Capture** tab: big "Scan Label" button (camera) and "Choose Photo". Allow multi-page capture via the document camera; process each page independently.
2. Run Vision OCR. Preprocess: correct orientation from EXIF, convert to grayscale, and if the label is not roughly upright, try rotations of 90/180/270 and keep the result with the most matched anchor keywords.
3. **Parse** with a dedicated `CVSLabelParser` (pure Swift, no UI, fully unit-testable). Strategy: anchor-keyword matching (`RX:`, `NDC:`, `QTY:`, `DAW:`, `DATE FILLED:`, `AMOUNT DUE:`, etc.) combined with line geometry (the value is on the same line to the right of the anchor, or on the next line). Use regexes tolerant of common OCR substitutions (`O`↔`0`, `l`/`I`↔`1`, `S`↔`5`, `$` dropped). Validate NDC as 5-4-2 digits. Parse money as `Decimal`, dates as `Date` with the `M/d/yy` format in `America/New_York`.
4. **Review screen**: show every parsed field in an editable form, with a per-field confidence tint (green/yellow/red) and the cropped image strip of the OCR line next to any low-confidence field. Fields that failed to parse are blank and highlighted. The user can fix anything before saving; any edit sets `wasEditedAfterScan = true`.
5. **Save** → run dedupe → create/attach `Medication`, `Pharmacy`, `Prescriber`, `InsurancePlan`, `Patient` → return to the Fills list with the new row highlighted.

## Manual entry

- "Add Manually" from the Fills list. Same form as the review screen, all fields optional except drug name, with pickers that offer existing pharmacies/prescribers/plans/patients. `source = .manual`. Show a clear "Manual entry" badge on the record thereafter.

## Screens

1. **Fills** (default tab): list of every fill, newest first. Row shows drug display name, date filled, NDC, qty/days supply, retail price, copay (amount due), and the source badge. Search by drug name / NDC / Rx number. Filter by medication, year, source. Sort by date filled, drug, copay. Swipe to delete (with confirmation).
2. **Medications**: one row per `Medication`, showing display name, strength/form, last fill date, last copay, last qty/days supply, refills remaining on the last fill, and an "estimated refill due" date. Toggle to hide inactive. Tap → medication detail with full fill history and totals (copay paid, retail value, number of fills).
3. **Fill detail**: a **reconstructed label view** that reproduces the CVS label layout — same section order, section headers ("Prescription Information", "Receipt & Refill Information", "Notes from the Pharmacy"), the shaded patient band, the four schedule boxes in their colors (morning gold, midday orange, evening blue, bedtime navy), the two-column receipt block, etc. This is a SwiftUI rendering from stored data, **not** the photo. Below it: source badge, confidence, created/edited dates, a "View original photo" button (if a scan), an Edit button, and "Re-run parser on stored OCR text".
4. **Settings**: Face ID lock toggle, export (CSV of all fills, and a JSON backup of everything), import JSON backup, "Delete all data".

## Code quality

- MVVM-ish: Views, `@Observable` view models, a `CVSLabelParser`, an `OCRService`, a `DedupeService`, a `PersistenceController`.
- Unit tests for `CVSLabelParser` using fixture OCR text files in `Tests/Fixtures/` (I'll add real ones; create at least one synthetic fixture matching the format above, including a slightly garbled variant with `O`/`0` confusion). Tests for dedupe logic and NDC normalization.
- Previews for every screen with sample data.
- Accessibility labels on all controls; Dynamic Type supported in the reconstructed label view (it may wrap, that's fine).
- `README.md` with build/run notes, and `DECISIONS.md` for any assumptions you made.

## Deliverable order

1. Project scaffold, SwiftData models, sample data, and the Fills + Medications lists with manual entry working.
2. OCR + parser + tests.
3. Scan/review flow and dedupe.
4. Reconstructed label view.
5. Settings, export/import, Face ID.

Commit after each step with a descriptive message.

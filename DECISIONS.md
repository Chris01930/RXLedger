# Decisions & assumptions

Choices I made where the spec left room. Each is easy to revisit.

## Project & tooling

- **XcodeGen** generates the project from `project.yml`, and the generated `.xcodeproj` is committed. This keeps the project file reviewable and avoids merge conflicts.
- **Swift 5 language mode** (`SWIFT_VERSION 5.0`, minimal concurrency checking), built with the Swift 6.2 toolchain in Xcode 26. This meets "Swift 5.10+" without strict-concurrency churn in SwiftUI/SwiftData code.
- **Swift Testing** (`@Test`, `#expect`) instead of XCTest. Tests run hosted in the app because the parser lives in the app target.
- The app icon is generated (teal gradient, "Rx" label card). Replace `RxLedger/Assets.xcassets/AppIcon.appiconset/AppIcon.png` whenever you like.
- `DEVELOPMENT_TEAM` is not set. Choose your team in Xcode before archiving.

## Data model

- **Every label field is stored on `Fill` as a snapshot** of what was printed, even though the fill also links to `Pharmacy`, `Prescriber`, `InsurancePlan` and `Patient`. Reasons:
  - the reconstructed label must show exactly what that label said, even after a pharmacy changes its phone number;
  - re-parsing or editing one fill never silently changes another.
  - The linked records hold the latest known values and feed the pickers.
- **CloudKit-ready**: every property is optional or defaulted, there are no `.unique` attributes, and all relationships are optional with inverses. The `ModelConfiguration` uses `cloudKitDatabase: .none` for now. Enabling sync later means adding the iCloud capability and changing that one line.
- `DataSource` is stored as `sourceRaw: String`, with a computed `source`, to stay predicate- and CloudKit-safe.
- **`FieldKey` / `FillDraft`**: one enum lists every label field (label, section, input kind). A string-based draft is shared by the parser output, all forms, JSON backup and CSV. Typed values (`Date`, `Decimal`, `Int`) are produced only when applied to a `Fill`. This keeps the form generic and keeps blank-versus-unparsed obvious.
- **DOB** is stored as the printed `M/YY` string. CVS prints no day, so a `Date` would invent one.
- **Quantity** is a `Double`, because labels can show fractional quantities such as 2.5 mL. **Money** is a `Decimal`.
- **Fill number** is kept as a string with its leading zero ("01").
- **Drug name** is stored exactly as printed, including CVS's `IC` (interchangeable/generic) prefix. Display name = drug name + strength/form.
- **Medication matching**: the key is `ndc:<11 digits>`, else `name:<normalized drug>|<normalized strength>`. If a drug was first entered manually without an NDC, the first fill that has an NDC adopts that medication instead of creating a second one.
- When a fill is deleted or re-pointed, **medications with no fills are deleted**. Pharmacies, prescribers, plans and patients are kept so they stay in the pickers.
- `Medication.isActive` is a user toggle. Inactive medications are hidden by default (toggle in the toolbar).

## Dates & time zone

- Label dates are parsed **and displayed** in `America/New_York`, as the spec requires. All list/detail date text uses those formatters, so a 6/23/26 fill never shows as 6/22 on a device set to Pacific time.
- Two-digit years map to 2000–2099.
- `createdAt` / `updatedAt` are real timestamps, shown in the device's time zone.

## Duplicate detection

- Key = `rxNumber-fillNumber` (fill number zero-padded to 2). The fallback is `ndc11-yyyy-MM-dd`.
- With neither available, a fill gets `unkeyed-<uuid>` and never matches anything.
- **Edit and re-parse** can't "replace" another record. If an edit would collide with a different fill, you get an alert offering *View Existing* or *Keep Editing*.
- **Replace with this scan** keeps the record's identity and `createdAt`, and swaps out its fields, OCR text and photo.
- JSON import skips any record whose id **or** dedupe key already exists.

## OCR & parsing

- **Capture** uses `VNDocumentCameraViewController` rather than `DataScannerViewController`, for perspective correction and multi-page capture. Each page is OCR'd and reviewed separately, and *Skip* moves on without saving.
- PhotosPicker allows up to 10 images at a time.
- **Orientation**: after the EXIF fix, the decision to rotate uses the **direction Vision says the text faces**, not only anchor-keyword hits. Vision often reads upside-down text correctly but returns its lines in reverse order, which scrambles positional parsing. I found this in testing.
  - Rotations are tried in the order Vision suggests, stopping once the text is upright and the label anchors are found.
- **Schedule boxes**: Vision tends to skip an isolated single character (the "1" in an Evening box). If the Morning/Midday/Evening/Bedtime header is found but no values are, the strip under it is cropped, upscaled 3× and OCR'd again.
- **Grayscale** uses a mild contrast boost; there's no thresholding. Vision does better on gray than on binarized images.
- **Confidence**: each field's confidence is the mean Vision confidence of the line(s) it came from, × 0.85 if the cleaner had to substitute characters (O→0 etc.). `ocrConfidence` is the mean over parsed fields. Tints: ≥ 0.8 green, ≥ 0.5 yellow, otherwise red. Crop strips appear for anything under 0.8 or unread.
- **Anchors** need their colon, except numeric ones (`NDC`, `QTY`, `DAW`, `BIN`, `DATE FILLED`, `AMOUNT DUE`…), which also match when followed by a digit or a digit look-alike. This keeps `GR: RX1234` from being read as an `RX:` anchor.
- **TP appears twice** (insurance block and side sticker). It's assigned by distance to the `BIN` line versus the `DRUG STORAGE TYPE` line.
- **`DATE:`** (no "FILLED") is always the side-sticker date.
- **Refills**: "No Refills" is stored as 0.
- **`RF`**: any `RF` token after the Rx/fill number sets `refillFlag`.
- **SEE DIRECTIONS** is stored in all four schedule fields and rendered as one spanning box.
- **Tuned against real labels (Nov 2026).** Two real photos showed the actual CVS layout differs from the original spec:
  - the schedule is a *vertical* column of icon cells (MORNING…BEDTIME), with "SEE DIRECTIONS" printed sideways;
  - the patient address is one line ("street, city, ST zip");
  - the receipt is two columns, and the right one repeats the drug name;
  - the bin/slot can be letters ("REF");
  - photos often include neighbouring labels.
  The parser now pre-filters lines (`CVSLabelParser+Prepare.swift`):
  - text clusters cut off at the left/right image edge are dropped as other labels;
  - schedule-word labels and sideways text are set aside, and decorative lines and tiny low-confidence fragments are dropped;
  - values are read only up to the first wide horizontal gap, so they don't run into the other column.
- **Document cropping was tried and removed.** Vision's document segmentation picked the "Notes" box as the document on one real photo and threw away the rest of the label.
- **Weak-line re-read**: lines that come back low-confidence or squashed are cropped, enlarged 3× and OCR'd again. This is an automatic version of "a higher-res image where needed". A re-read never extends into a neighbouring line that was already read well, and schedule labels are never re-read.
- **SEE DIRECTIONS** is found by re-reading the schedule column rotated 90°/270°. The column is located from the schedule labels, or from the page layout when Vision misses them.
- **Drug lines** are joined and split at the strength ("IC RAMIPRIL 10 MG" + "CAPSULE" → "IC RAMIPRIL" / "10 MG CAPSULE"), because where the label breaks the line varies by drug.
- **Close-ups of one label** (Capture → "Part of one label"): each photo is read on its own at full resolution and the results are merged field by field.
  - The value seen in the most photos wins, weighted by confidence. Readings within 3% of a photo's top/bottom edge count 30% less, since they're the likeliest to be cut off. Near-ties go to the longer value; for bullets and notes, the most complete reading wins.
  - The photos are stacked into one tall image for the record (up to 1600 px per photo, 3 photos max at full size), and OCR lines carry a `page` tag so *Re-run Parser* re-merges correctly.
  - I chose this over stitching the photos into one seamless image: aligning hand-held close-ups well enough for OCR is fragile and slow on-device, while merging per-photo results is robust to any overlap.
- Expect further tuning as more real labels come in. Each scan keeps the raw OCR lines with bounding boxes, so *Re-run Parser* will apply future parser improvements to existing records. Each scan keeps the raw OCR lines with bounding boxes, so *Re-run Parser* will apply future parser improvements to existing records.
- *Re-run Parser* opens the review form with the new values and doesn't save until you confirm. Any manual edits you made earlier are replaced by what you save there.

## UI

- **Form section order** is Prescription → Receipt & Refill → Insurance → Pharmacy → Patient → Header → Notes → Side sticker, rather than strict label order. The fields you check most come first. Manual entry and review use the same form, as the spec asks.
- Dates are typed as `M/D/YY` (with a calendar button that fills in today for date fields). A date picker would make "blank" and "unread" awkward to show.
- Saving is blocked when any non-empty field fails validation, so data is never silently dropped. Drug name is the only required field.
- In the review form, a blue tint and pencil mark fields you changed. Any change from the parser output sets `wasEditedAfterScan`.
- The reconstructed label is always drawn in light mode (it represents paper), and its columns stack at accessibility text sizes. The barcode is regenerated as Code 128 from the stored digits; it's a stand-in, not a scannable copy of CVS's symbology.

## Security & privacy

- The app lock uses `.deviceOwnerAuthentication` (Face ID / Touch ID with passcode fallback), is on by default, and locks on entering the background. Content is hidden whenever the app isn't active, which covers the app-switcher snapshot.
- Turning the lock **off** requires authenticating.
- If the device has **no passcode**, the app can't be locked. It opens and tells you why instead of locking you out of your data.
- There is no networking code at all. The JSON backup includes photos and OCR text, so treat exported files as sensitive.

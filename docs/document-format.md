# Document format (the `.kisaca` package)

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

`LectureDocument` is a **package document** (a directory, like `.pages` or `.key`), not a single
file — because it holds many independent binary blobs (one PaperKit markup per page) that we want
to save incrementally, not re-serialize as one giant blob on every keystroke.

```
MyLecture.kisaca/                  (directory; UTType com.igalhan.kisaca.lecture, LSTypeIsPackage)
├─ manifest.json                   (LectureManifest, JSON)
├─ Pages/
│   └─ <page-uuid>.paperkit        (PaperMarkup.dataRepresentation(), one per page, any session)
├─ Thumbnails/
│   └─ <page-uuid>.ink.png         (cached snapshot of the page's ink only, transparent — no
│                                    paper, no grid; used for pages without a live canvas and
│                                    for the PDF page picker)
└─ Materials/
    └─ <material-uuid>.<ext>       (the lecture's own files — scripts, slides, sheets; listed in
                                     manifest.materials, see "Materials" below)
```

Thumbnails were `<page-uuid>.thumb.jpg` until 2026-09-24: opaque JPEGs with the grid baked in,
which would now show a second, blurry grid under the live one. Old `.thumb.jpg` files are not
read; pages without an `.ink.png` get one regenerated from their markup when their tile first
appears (`NotebookScrollViewController.regenerateThumbnail`), and the old files drop out on the
next save because `fileWrapper` rebuilds `Thumbnails/` from `thumbnailData`.

`LectureDocument` conforms to `ReferenceFileDocument` (a **class**, not a struct) because:
1. PaperKit/PencilKit editing state is inherently reference-based and high-frequency (every pen
   stroke), and we don't want SwiftUI diffing a giant value-type document on every stroke.
2. `ReferenceFileDocument.snapshot(contentType:)` lets us hand the system an immutable, `Sendable`
   copy (`LectureDocument.Snapshot`) to serialize, decoupled from the live, mutable object —
   `fileWrapper(snapshot:configuration:)` only ever touches that copy, never `self`. (This copy is
   currently built and serialized on the main actor rather than a background one — see
   [actor-isolation.md](actor-isolation.md) for why — but the snapshot indirection is what would make
   moving it off-main-actor a contained change later, not a redesign.)

`fileWrapper(snapshot:configuration:)` reuses unchanged child `FileWrapper`s from
`configuration.existingFile` (comparing raw bytes) instead of always rewriting every page —
standard practice for package documents (same idea Xcode/Pages use), so saving one page's
markup doesn't rewrite every other page's file on disk.

## Format versions (2026-10-31)

`manifest.json` carries two numbers:

- `schemaVersion` — the format of the build that last saved the file. Informational.
- `minimumReaderVersion` — the oldest format a build must support to open the file without
  misreading or losing anything. Absent in version-1 files (= 1).

`LectureManifest.currentFormatVersion` is what this build reads and writes. Every save stamps
both fields with it (`LectureDocument.fileWrapper`). On open, `LectureDocument.load` reads
`minimumReaderVersion` *before* decoding the full manifest and throws
`LectureFormatError.needsNewerApp` if it is higher; `LectureLibrary.open` passes that on, so the
user sees "saved by a newer version of KISACA" instead of a generic failure. If a newer build
saves the file while an older one has it open (iCloud), the reload fails the same way and
`LectureFile.contents(forType:)` refuses to save, so the stale in-memory copy never overwrites it.

**When to bump:** raise `currentFormatVersion` for any change an older build would get wrong —
misrender, or drop on its next save (`Codable` silently discards keys it doesn't know). An
optional field an older build can ignore without harm needs no bump. Builds before version 2
don't check at all; that can't be fixed retroactively.

| Version | Change |
|---|---|
| 1 | Everything up to 2026-10-31. |
| 2 | Ink space for new pages is 1.6× A4 (see below). A version-1 build would show only the top-left part of such a page. |

### Ink scale (version 2)

Pens looked thicker than in Apple Notes. Cause: page markup was `PaperMarkup(bounds: 595×842)`
(A4 in PDF points), and fit-to-width on a 13" iPad stretches that ~1.6×. Pen widths, text sizes
and shape strokes are in *markup* coordinates, so every stroke was magnified with the page; Notes
draws one ink point per screen point.

New pages are now `PaperMarkup.blankPage()` = A4 × `PageGeometry.inkScale` (1.6 → 952×1347),
which on a 13" iPad in portrait is 1:1 with the screen. The rest of the app (layout, grid,
`visiblePageRect`, thumbnails, PDF) still works in 595×842 page points; only the PaperKit
boundary converts:

- `PageCanvasController.show(_:)` sets the markup, `inkScale` and the content view's frame from
  the markup's own `bounds`; `fitA4InViewport`/`sizePaperVCToFillPage` scale `visiblePageRect`
  by it.
- `PageRenderer.renderInk` scales the context by `1 / markup.inkScale` and draws the markup in
  its own bounds.

**Old pages are not migrated.** A page's markup stores its bounds, so `PaperMarkup.inkScale`
reads 1 for old pages and their ink keeps its exact size and position. A session can therefore
mix old (thicker-looking) and new pages; "Clear page" turns a page into a new-format one.
Pasting ink from an old page onto a new one keeps its markup-point size, so it lands ~1/1.6 as
big.

Verified in the simulator (iPad Air 13", 2026-10-31) with a real version-1 lecture: the old
stroke shows where it was drawn, its thumbnail regenerated by the new renderer is byte-identical
to the old one, the old page file was not rewritten, new-page strokes follow the touch across the
whole page and measure ~5 px vs ~8–9 px for the same pen on the old page, and both fields read 2
after saving. A copy with `minimumReaderVersion: 3` showed the "newer version" alert and was left
unmodified. **Not verified:** Apple Pencil feel on the device, PDF export of a mixed session
(same renderer as the thumbnails, so expected to be right).

## Grid size (2026-09-26)

Each session stores its grid square side as `gridSpacingMM` in `manifest.sessions[]`
(`LectureSession.storedGridSpacingMM`). New sessions get 6.5 mm. A session without the key was
written on the old fixed 5 mm grid and reads as 5 mm, so its ink keeps lining up with the lines —
except one with no ink yet (a timetable meeting generated ahead of time), which `init(configuration:)`
moves to 6.5 mm since there is nothing to misalign. Screen, placeholder tiles and PDF export all
take the size from the page's session (`PageRepository.gridSpacing(forPageAt:)`).

## Materials (2026-09-24)

The lecture's own files — scripts, slides, exercise sheets — live in the package, so they sync
and move with the lecture. `manifest.materials` (`[CourseMaterial]?`, absent in older files)
describes them: title, original file name, UTType, size, and an optional `week` (1-based semester week; absent = whole lecture — older files decode as whole-lecture). The bytes are `Materials/<uuid>.<ext>` —
named by ID so two "Script.pdf" imports can't collide.

**The bytes are not loaded when the document opens**, unlike page ink: a semester of PDFs can be
hundreds of MB. Instead:

- Newly added (or marked-up) files are held in `LectureDocument.newMaterialData` for the session.
- `fileWrapper(snapshot:configuration:)` writes those from memory and **reuses the existing file
  wrapper** for every other material (`configuration.existingFile`, falling back to the wrappers
  captured at open) — so an unchanged file is neither read nor rewritten by a save. A removed
  material is simply not carried over, which deletes it.
- Opening one reads it on demand from the live package URL (off the main actor), falling back to
  the wrapper captured at open.

**Viewing is read-only** (decided 2026-09-24): materials are reference copies, notes go in the
notebook. `MaterialsViewController` (was `MaterialsView`) writes the file under its original name to a temp folder and presents
`QLPreviewController` (`MaterialPreviewer`) with `editingModeFor → .disabled`, so Quick Look offers
no Markup button. (SwiftUI's `quickLookPreview` shows one, and its edits land on the temp copy and
vanish on close.) A first version wrote Markup back into the lecture; it was removed at the user's
request. Lesson kept from it: Quick Look's delegate is not guaranteed to run on the main thread —
hop explicitly before touching the document, or `updateChangeCount` never schedules an autosave.

**Beside the notebook.** `NotebookViewController`'s split button opens a material in `MaterialPaneViewController` next to
the canvas — PDFKit for PDFs, embedded Quick Look for anything else, also read-only. Which side it
opens on (left by default) and its width are device preferences, see `Settings/AppPreferences.swift`.

**Reading position (2026-10-31).** A PDF reopens where it was left — page, the point at the
top-left of the view, and zoom relative to fit-width (so a position taken in the narrow pane fits
full screen too). `ResumingPDFView` (`Lecture/MaterialReadingPosition.swift`) restores on its
first real layout (before that `PDFView` ignores `go(to:)` and has no fit scale) and saves on
page change, on leaving the window and on scene deactivation. Used by the pane and by
`MaterialPDFReaderViewController`, which is why full-screen PDFs from the Materials list no longer
go through Quick Look: Quick Look has no API to read or set a page. Positions live in
`UserDefaults` keyed by material ID, **not in the package** — scrolling is not an edit, and
writing it to the lecture would mean a save, an iCloud upload and a conflict risk per page turn.
Consequence: positions don't follow the lecture to another device. Deleting a material forgets
its position.

Verified in the simulator: import from Files (multiple), preview a PDF and a TXT, relaunch and
reopen (bytes read from disk), the untouched file's mtime unchanged across saves (wrapper reused),
delete → file gone from the package. **Not tested:** drag-and-drop import (needs a second app side
by side), a large (100 MB+) file.

## Autosave design

> **Correction (verified in the simulator, 2026-09-23).** An earlier version of this section said
> `DocumentGroup` saves whenever the document's `objectWillChange` fires. **It does not.** For a
> `ReferenceFileDocument`, SwiftUI learns about edits from the undo manager, and none of this app's
> manifest edits register undo actions. So a lecture that was set up and renamed but never drawn
> on was never written to disk: `snapshot(contentType:)` was never called, and `manifest.json`
> stayed at "New Lecture" / `needsSetup: true` even after closing the document. Drawing only
> saved things as a side effect of PaperKit registering its strokes with that same undo manager —
> and even then the page bytes could be captured *before* the timer flush (below) had written the
> latest strokes into `pageData`.

Dirtiness is therefore stated explicitly. `LectureDocument.markDirty()` calls
`updateChangeCount(.done)` on the live `UIDocument` behind the model (`LectureFile`, stored in
`LectureDocument.host`; before 2026-09-28 it was DocumentGroup's, found by `DocumentHost.swift`). It is called
from `manifest`'s `didSet` — every manifest mutation, including in-place ones like
`manifest.sessions.append(…)` — and from `setPageData`, `setThumbnailData` and
`pruneOrphanedPageData`. `UIDocument` then autosaves on its own schedule; **observed ~10–20 s
after the edit, not instantly.** Observation (below) is separate and has nothing to do with saving.
If `host` is `nil`, `markDirty()` is a no-op.

**Observation (since 2026-09-28, UIKit migration step 0.2).** `LectureDocument` is `@Observable`
(it was an `ObservableObject` with `@Published var manifest` while it was a
`ReferenceFileDocument`). Only `manifest` and `pageContentRevision` are observed. The page and
thumbnail dictionaries are `@ObservationIgnored`; every change to them bumps
`pageContentRevision` (where `objectWillChange.send()` used to be). A view that shows something
derived from page data — a session row's "No notes yet", the Whole Notebook row, export
thumbnails — reads `pageContentRevision` explicitly. `getPageData`/`getThumbnailData` deliberately
don't read it: UIKit tracks `@Observable` reads during layout, and the notebook reads page data all
the time.

**Page markup** is intentionally *not* observed (see point 1 above — we don't want every pen
stroke re-rendering views). Converting a live `PaperMarkup` to `Data` is also `async`, so it
can't happen synchronously inside the UIKit delegate callback anyway. Instead:

- Each pooled canvas slot (`PageCanvasController`) keeps the freshest in-memory `PaperMarkup` for
  whatever page it currently shows (`latestMarkup`), updated via the PaperKit delegate callback.
- `PageRepository.saveMarkup(_:forPageAt:)` awaits `dataRepresentation()` and hands the bytes to
  `LectureDocument.setPageData(_:for:)`, which stores them and calls `markDirty()` (see above) —
  that is what tells the system "this document has unsaved changes, please autosave."
- This flush happens: (a) the instant a page's cell scrolls off screen
  (`NotebookScrollViewController.collectionView(_:didEndDisplaying:forItemAt:)` — see
  [notebook-canvas.md](notebook-canvas.md)), which covers every page except whichever one currently has the tool picker; (b)
  a periodic ~8s timer that flushes specifically the active page (`NotebookCoordinator`'s autosave
  timer), covering the case where the user sits and writes on one page for a long time without
  scrolling; (c) on `scenePhase` → `.background`/`.inactive`; and (d) right before PDF export.

This is a pragmatic MVP autosave — not perfectly real-time (worst case ~8s of drawing on the
active page could be lost on a hard crash; every other page is already saved as soon as it
scrolls away), but simple and well-understood. **If tighter durability is needed later**, the
next step would be debouncing `markDirty()` on every markup-changed delegate callback directly
(skipping the timer) — flagged here rather than implemented, to avoid over-engineering
before it's asked for.

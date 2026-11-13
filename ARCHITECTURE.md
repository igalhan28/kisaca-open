# KISACA — Architecture & Progress Log

> **Read this file first after any context refresh.** It says what this project is, what's done
> and what's next, and points to the topic docs in `docs/` — open only the one(s) your task
> touches. Update the **Status** section whenever you finish or start a task; write design and
> bug history into the matching topic doc, not here.

## Where everything else lives

| Doc | Read it when you touch… |
|---|---|
| [library.md](docs/library.md) | the **home screen**, where lectures are stored (iCloud container / On My iPad), opening/closing, import — replaced `DocumentGroup` |
| [data-model.md](docs/data-model.md) | `LectureManifest`, sections, sessions, **routines** (semester, naming, generated sessions), whole-section notebook |
| [document-format.md](docs/document-format.md) | the `.kisaca` package, `LectureDocument`, **autosave / `markDirty()`**, **materials** (files stored in the lecture) |
| [naming.md](docs/naming.md) | lecture name ↔ file name, renaming (incl. the real-iPad permission bug) |
| [notebook-canvas.md](docs/notebook-canvas.md) | page canvas & pager, memory, active page & tool picker, dark mode, page turns, Pencil latency |
| [sidebar.md](docs/sidebar.md) | the notebook's **chrome**: sidebar (`ToolRailView`), applets (Materials, Pages), status strip, export button, tool wheel, hiding the chrome, handedness preferences |
| [notebook-zoom.md](docs/notebook-zoom.md) | pinch zoom, `commitZoom`, thumbnail ↔ canvas swap |
| [notebook-bug-history.md](docs/notebook-bug-history.md) | past notebook crashes and their lessons — skim before changing canvas lifecycle code |
| [actor-isolation.md](docs/actor-isolation.md) | isolation of `LectureDocument` / `LectureFile` — **read fully first** |
| [build-notes.md](docs/build-notes.md) | building from the command line, project setup quirks |
| [decisions.md](docs/decisions.md) | why one document per lecture, `ReferenceFileDocument`, MainActor default |
| [file-map.md](docs/file-map.md) | where a file lives / what a file is for |
| [uikit-migration.md](docs/uikit-migration.md) | the **SwiftUI → UIKit migration** (branch `uikit-migration`): plan, phases, progress, checklist |

## What this is

**KISACA** ("kısaca" — "briefly" in Turkish) is an iPadOS/iOS note-taking app for students, built with
UIKit + [PaperKit](https://developer.apple.com/documentation/paperkit) (iOS/iPadOS 26+); only the forms
(`Forms/`) are SwiftUI, hosted in `UIHostingController`s. It was a SwiftUI app until the migration of
2026-09-28 – 09-30 ([uikit-migration.md](docs/uikit-migration.md)).
It is *not* a generic notebook app — notes are organized around a student's actual course
structure: **Lecture → Section → Session (dated notebook)**.

Example: `Calculus II → Exercise Sessions → 29.10.2026` opens an infinite-scrolling,
paginated A4 notebook for that specific exercise session.

## Developing on several devices

Development now happens on more than one Mac, so **this repository is the single source of
truth for the docs**: `ARCHITECTURE.md` at the root and the topic docs in `docs/` (moved here
on 2026-11-13 from the un-versioned parent folder, where `sidebar.md` had been written on the
`sidebar` branch in parallel).

- **Pull before you start, commit and push the docs with the code they describe.** Two
  machines editing the Status section at once will conflict; resolve it by keeping both
  entries.
- **Nothing outside this repo travels.** Each Mac has its own Claude memory, simulator
  setup, paired iPads and DerivedData. Anything another machine needs to know goes into
  these docs, not into local notes.
- Paths in these docs are relative to the repository root (the folder holding
  `kisaca.xcodeproj`). The app target's sources are in `kisaca/`.

## Repository layout — and the prototype outside it

| Folder | What it is | Status |
|---|---|---|
| `Delve.swiftpm/` (outside this repo, a sibling folder on the original Mac only; local git, no remote) | The **original prototype**, built as a Swift Playgrounds app. Historical only — the app's document model (`Models/`, `Document/`), navigation (`Views/`), and notebook canvas (`Notebook/`) have all since been built independently in `kisaca/`. Nothing in `kisaca/` is ported from or patterned after this anymore. Kept only in case some Delve-era detail is worth cross-checking. | Frozen reference |
| this repo | The **real app**: an Xcode project where each Lecture is a real, file-based, iCloud-syncable `.kisaca` package. It started as a `DocumentGroup` app; since 2026-09-28 it has its own home screen and library instead (see [library.md](docs/library.md)). **This is where all active development happens.** | Active |

The user's own conclusion (see project brief) was that a Swift Playgrounds app was the wrong
container for a real product, and a document-based iOS app is correct. Early on, `Delve.swiftpm`'s
canvas engine was ported into `kisaca/` as a starting point; the notebook canvas has since been
rebuilt from scratch twice more as requirements sharpened (see [notebook-canvas.md](docs/notebook-canvas.md)) and no
longer shares code or structure with Delve at all.

---

## Status & Next Steps

Legend: `[x]` done · `[~]` in progress / partially done · `[ ]` not started

### Phase 1 — Document foundation
- [x] `ARCHITECTURE.md` written (this file; split into `docs/` topic files 2026-09-24)
- [x] Data model (`LectureSection`, `ScheduleSlot`, `LectureSession`, `LectureManifest`) — `Models/LectureModels.swift`
- [x] `UTType` for the `.kisaca` package document — `Document/UTType+Kisaca.swift`
- [x] `LectureDocument: ReferenceFileDocument` (package read/write) — `Document/LectureDocument.swift`
- [x] `Info.plist` updated with the new document type; old `com.example.plain-text` type removed
- [x] Old boilerplate `kisacaDocument.swift` deleted; `kisacaApp.swift` updated to use `LectureDocument`

### Phase 2 — Navigation & lecture setup
- [x] `Forms/LectureSetupView.swift` (was `Views/`) — new-lecture flow: name, section picker (recommended + custom), schedule builder
- [x] `Views/LectureHomeView.swift` — list of sections in a lecture (UIKit since 2026-09-29: `Lecture/LectureHomeViewController.swift`)
- [x] `Views/SectionSessionsView.swift` — list of dated sessions in a section, add-session flow (UIKit since 2026-09-29: `Lecture/SectionSessionsViewController.swift`)
- [x] `ContentView.swift` — root switch: shows setup sheet for a fresh document, else `LectureHomeView`
- [x] Lecture name ↔ document file name kept equal in every rename path — see [naming.md](docs/naming.md)
- [x] One navigation bar, one back button. `ContentView.hidingDocumentGroupNavigationBar()` removes
      the UIKit document bar `DocumentGroup` stacks above the editor, and the rename menu is
      re-hosted in our `NavigationStack`'s bar. Back-to-the-browser is **not** re-hosted:
      DocumentGroup still puts its own close chevron into that bar's leading position, so the
      hand-rolled `dismiss()` chevron that used to sit next to it (in `LectureHomeView` and
      `LectureSetupView`) was a visible duplicate doing the same thing, and was removed
      (2026-09-23, verified in the simulator: one chevron, and it returns to the browser).

### Phase 3 — Notebook canvas
- [x] `Utils/GridBackground.swift` — grid is 5 mm squares, 0.5pt lines (page space); the numbers
      live only in `PageGeometry.gridSpacing` / `gridLineWidth`, shared by canvas, tiles and PDF
      export (2026-09-24; was 25pt ≈ 8.8 mm / 1pt, hard-coded in three places)
- [x] Grid is sharp at every zoom (2026-09-24) — see [notebook-canvas.md → Grid](docs/notebook-canvas.md)
- [x] `Utils/PDFExporter.swift` — exports a full session or an explicit page-index subset
- [x] `Notebook/PageGeometry.swift` — shared A4 size constant
- [x] `Notebook/PageRepository.swift` — page list + markup/thumbnail read-write against `LectureDocument`
- [x] `Notebook/PageCanvasController.swift` — one page: a PaperKit canvas filling the width it is
      given, owning its own scroll and zoom (Apple's template shape) — see [notebook-canvas.md](docs/notebook-canvas.md)
- [x] `Notebook/NotebookPagerViewController.swift` — one page at a time, turned with a Books-style
      page curl (`UIPageViewController`); turning past the last page adds one. Replaced the continuous
      scroll (`NotebookScrollViewController` + `NotebookPageTileView`) on 2026-11-01 for Pencil latency
- [x] `Notebook/NotebookCoordinator.swift` — observable state between the bar and the canvas
      (page counter, bar actions, autosave timer, PDF export trigger)
- [x] `Notebook/NotebookViewController.swift` — the screen hosting the canvas for one `LectureSession`
      (UIKit since 2026-09-28; was the SwiftUI `NotebookScreen` + `NotebookHostView` bridge)
- [~] **Notebook chrome & gestures (2026-11-09 → 11-13)** — no nav bar: a black sidebar
      (`ToolRailView`) pinned to one screen edge (left, or right when left-handed) with a status
      strip across the top. It launches **applets** — Materials and Pages (thumbnails,
      `PageThumbnailsViewController`) — and holds the drawn tools, colours, widths, undo/redo.
      A two-finger swipe opens the click-wheel **tool wheel** (`ToolWheelView`, recently used
      combinations; replaced the half-disc tool disk). A floating liquid-glass **Export** button
      sits in the notebook's top corner (back since 2026-11-13). The system picker stays
      attached but `.hidden` (PaperKit won't edit without one); pages turn only from the edge
      zones, one finger, at 2× speed; a finger **double-tap** hides all chrome + status bar.
      Simulator finger ink is opt-in (`-KisacaFingerInk YES`). Merged into `main` from the
      `sidebar` branch (PR #1). Verified in the simulator; **check on the iPad:** Pencil ink with
      the hidden picker, double-tap eraser. See [sidebar.md](docs/sidebar.md) and
      [notebook-canvas.md → Notebook chrome & gestures](docs/notebook-canvas.md).
- [x] `Notebook/PDFExportViewController.swift` — "All Pages" vs "Select Pages" (thumbnail grid +
      checkmarks; was the SwiftUI `PDFExportSheet`)
- [~] Acting on a PaperKit selection from our own toolbar. PaperKit's long-press menu ("Copy as
      Text") takes no custom items, so the "Selected Text" bar button in `NotebookViewController`
      reads `selectedMarkup` itself and shows the extracted text in an alert. This is a probe,
      not the final feature — it exists to find out on a real iPad whether `indexableContent`
      covers handwriting or only text boxes. See [notebook-canvas.md](docs/notebook-canvas.md).

### Phase 4 — Autosave, polish, validation
- [x] Autosave strategy implemented (see [document-format.md → Autosave design](docs/document-format.md)) — timer + lifecycle flushes
- [x] Document dirty-tracking fixed: manifest/page edits now call `markDirty()` (they previously never
      triggered a save on their own — see [document-format.md → Autosave design](docs/document-format.md))
- [x] Build verified: `xcodebuild` succeeds clean (no errors, no warnings) for iPad Pro 11-inch
      (M5) simulator, iOS 26.2 SDK. One fix was needed vs. the design as first written: see
      [actor-isolation.md](docs/actor-isolation.md).
- [x] Runtime smoke test: installed + launched on the iPad Pro 11-inch (M5) simulator. App
      launches without crashing; `UIDocumentBrowserViewController` renders correctly with the
      `kisaca` branding and a working "Create Document" button (confirms the `.kisaca`
      UTType/Info.plist registration is correct end-to-end).
- [~] Full flow only partly exercised at runtime. Driven by hand through the simulator (2026-09-23):
      "Create Document" → `LectureSetupView` → `LectureHomeView` → rename (both paths) → close →
      reopen, checking `manifest.json` and file names on disk. 2026-09-24: routine sheet →
      `SectionSessionsView` → `NotebookScreen` (single session and whole section) → drawing also
      driven in the simulator — simulator touches *draw* on the canvas (they count as pencil input
      there), so ink can be tested without a device. **Still not exercised:** PDF export.
      (No XCUITest target exists yet; `simctl` alone can't synthesize touches.) **Next session: either add a thin UI test target,
      or just run it in Xcode and drive it by hand** — this is the highest-value next step,
      since the whole view graph compiles but has only been proven correct by reading, not by
      exercising it.
- [ ] Manual smoke test on a real iPad with Apple Pencil (cannot be done from this environment)
- [~] Thinner ink + format versioning (2026-10-31): new pages use a 1.6× ink space so pens match
      Notes; old pages untouched; `manifest.json` gains `minimumReaderVersion` and newer-format
      files are refused instead of misread. Verified in the simulator, **not yet on the iPad** —
      see [document-format.md → Format versions](docs/document-format.md)
- [x] Lecture routines (2026-09-24) — semester dates, several weekly meeting times per section,
      per-section naming ("W3 · Mon" / "Assignment 3"), sessions generated for the whole semester,
      editable after setup from the lecture's calendar button, and a **Whole Notebook** per section
      (all its sessions as one book). See [data-model.md → Routines](docs/data-model.md).
- [x] Course materials (2026-09-24) — a **Materials** row at the top of the lecture's home screen:
      scripts/slides/sheets imported from Files or by drag-and-drop, stored in the package's
      `Materials/` folder (not loaded into memory), opened **read-only** in Quick Look.
      See [document-format.md → Materials](docs/document-format.md).
- [x] Material beside the notebook (2026-09-24) — split button in the notebook's bar opens a
      material in `Notebook/MaterialPaneViewController.swift` (was `Views/MaterialPane.swift`) next to the canvas (PDFKit / embedded Quick Look,
      read-only), resizable by dragging the divider (applied on release). Side (left by default)
      and width are **device preferences** in `Settings/AppPreferences.swift` (`UserDefaults`,
      `@AppStorage`) — no settings screen yet; a later one reads/writes the same keys. The pane's
      PDF view takes first responder, which hid the tool picker for good;
      `NotebookPagerViewController.reclaimToolPicker()` takes it back on any notebook touch and
      after the pane opens/closes (verified in the simulator: picker back, drawing works with the
      pane open). **Known:** the floating tool picker can sit over the pane's header.
- [~] **Ink not reaching disk — simulator only, as far as known (2026-09-24).** In the simulator,
      strokes drawn with simulated touches show on screen and in the saved thumbnail, but the page's
      `.paperkit` file stays blank (244 bytes). The user reports no such problem on their iPad, so
      it is treated as a simulator artifact (likely: simulated touches draw but don't go through
      PaperKit's markup-changed path) until a device shows otherwise. Consequence: **ink
      persistence can't be verified in the simulator — check it on the iPad.** If it ever shows up
      on a device, the save path is `PageCanvasController.latestMarkup` (delegate) → `flush` →
      `PageRepository.saveMarkup` → `LectureDocument.setPageData` → `markDirty`.
- [x] **Materials resume where they were left (2026-10-31)** — PDFs reopen at the same page,
      scroll point and zoom, in the pane and full screen. Full-screen PDFs from the Materials list
      now open in PDFKit (`MaterialPDFReaderViewController`) instead of Quick Look, which can't be
      told a page; other file types still use Quick Look and start at the top. Positions are
      device-local (`UserDefaults`), see [document-format.md → Materials](docs/document-format.md).
      Builds; **not yet exercised at runtime** (needs a lecture with a PDF in the simulator).
- [x] **Pencil-only editing; read-only notebook on iPhone (2026-10-31)** — see
      [notebook-canvas.md → Pencil-only editing](docs/notebook-canvas.md). Builds; **check on the
      iPad:** finger can't select/move ink or edit text boxes, Pencil still draws, lassoes, taps.
- [ ] Materials follow-ups: link a material to a section/session, folders, PDF thumbnails in the list
- [ ] Section editing after initial setup (rename, add/remove section) — **not built yet**
- [ ] Routine follow-ups: holidays / skipped weeks, and removing the sessions of a meeting time
      that was deleted (generation is additive only, on purpose — they may hold notes)
- [ ] Deleting sessions/sections (currently additive-only — no delete UI yet)
- [x] Branding is **KISACA**, uppercase, everywhere the user sees it (2026-09-24). Note that the
      displayed name is now decoupled from the target name: there was no `CFBundleDisplayName`, so
      the Home Screen and document browser showed `PRODUCT_NAME` (= the target, `kisaca`).
      `INFOPLIST_KEY_CFBundleDisplayName = KISACA` in both build configs fixes that without
      renaming the target, module or bundle ID. The `.kisaca` extension, the
      `com.igalhan.kisaca.lecture` UTI and `com.igalhan.kisaca` stay lowercase **on purpose** —
      changing them orphans every document already on disk and in iCloud.
- [ ] Empty-states polish, app icon, launch screen
- [x] **Own home screen instead of the document browser (2026-09-28)** — `DocumentGroup` removed.
      Lectures live in the app's iCloud container (`iCloud Drive › KISACA`) or, without iCloud,
      `On My iPad › KISACA`; Import copies `.kisaca` files in. Home screen: Upcoming / Last
      Sessions + one shelf per lecture, cards show the first page. See [library.md](docs/library.md).
      Verified in the simulator; **still to do on the iPad:** import the lectures from
      `iCloud Drive/ETHSAL/ kısaca/`, check iPad ↔ iPhone sync.

### Phase 5 — UIKit migration
- [~] SwiftUI → UIKit (2026-09-30: Phases 0–6 done except the last step — every screen is UIKit;
      the forms (setup, routine, settings, new session) stay SwiftUI by decision, in `Forms/`,
      hosted. **Before merging into `main`: the iPad check** — ink, memory, Files open, the
      black-window fix; see [uikit-migration.md → Progress](docs/uikit-migration.md)). Branch `uikit-migration` in `kisaca/`;
      SwiftUI baseline on `main` at `1b26465`. Plan and progress: [uikit-migration.md](docs/uikit-migration.md).

### Known gaps / deliberately deferred (do not treat as bugs)
- No paper resizing, templates, or multiple paper sizes — **explicitly out of MVP scope** per project brief.
- No cross-lecture search, no tags, no cloud backend beyond iCloud Drive (the app's container).
- No section/session deletion or rename UI yet (Phase 4 backlog item above).

## Glossary

- **Lecture** — a course, e.g. "Calculus II". = one `.kisaca` document.
- **Section** — a category within a lecture, e.g. "Exercise Sessions". Recommended defaults:
  Lectures, Exercise Sessions, Labs, Assignments. User can add custom ones.
- **Session** (`LectureSession`) — one dated notebook instance inside a section, e.g. "29.10.2026".
  This is what actually holds pages/ink.
- **Page** — one A4 sheet of `PaperMarkup` ink inside a session. Sessions can have any number of
  pages, presented as one continuous vertical scroll (see [notebook-canvas.md](docs/notebook-canvas.md)).
- **Canvas slot / pooled canvas** (`PageCanvasController`) — one reusable unit of *live* PaperKit
  state, bound to whichever page is currently scrolled into view. Not the same thing as a page —
  there are only ever a handful of these regardless of how many pages a session has (see
  "Notebook canvas → Memory management").

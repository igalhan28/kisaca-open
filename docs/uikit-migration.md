# UIKit migration

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).
> Work happens on the `uikit-migration` branch of `kisaca/`; the SwiftUI app is preserved on
> `main` at `1b26465` ("SwiftUI baseline before UIKit migration").

## Goal and end state

The app lifecycle, navigation and screens move from SwiftUI to UIKit. Two layers are **not**
rewritten:

- **The notebook core is already UIKit** and stays as it is: `NotebookScrollViewController`,
  `PageCanvasController`, `NotebookPageTileView`, PaperKit. Only the SwiftUI chrome around it
  (`NotebookScreen`, `NotebookHostView`) is replaced.
- **The model and file layer stays**: `LectureDocument`, `LectureFile`, `LectureLibrary`,
  `DocumentNaming`, `DocumentConflictResolver`, `PageRepository`, `PDFExporter`, `PageRenderer`.
  The one change is how `LectureDocument` is observed (step 0.2).

**Decided 2026-09-30 — the forms stay SwiftUI** (in `Forms/`, hosted). What follows was the open
question: `LectureSetupView`, `RoutineEditor`/`RoutineSheet`,
`LibrarySettingsView` and the add-session sheet are `Form`s, which SwiftUI does well and UIKit
does verbosely. They stay SwiftUI inside `UIHostingController` until everything else is done;
Phase 5 decides whether they are rewritten.

## Rules for every step

- **The app builds and runs after every step, and every step is one commit.** A step that
  can't reach that is split.
- **Navigation first, then one screen at a time.** Until a screen is converted it runs as
  SwiftUI in a `UIHostingController` that UIKit pushes.
- **Same behaviour, not a redesign**: same titles, buttons, alerts, empty states and wording.
  Improvements go in their own commits after the matching screen is done.
- **Don't change**: isolation of `LectureDocument` / `LectureFile` ([actor-isolation.md](actor-isolation.md)),
  canvas lifecycle ([notebook-bug-history.md](notebook-bug-history.md)), file coordination and
  naming ([naming.md](naming.md)).

## What replaces what

| SwiftUI today | UIKit replacement |
|---|---|
| `kisacaApp` (`@main App`, `WindowGroup`) | `AppDelegate` + `SceneDelegate` |
| `LibraryRootView` (`NavigationStack`/`NavigationPath`, `onOpenURL`, `scenePhase`, error alert) | `AppCoordinator` that owns the `UINavigationController` |
| `LibraryHomeView`, `ShelfScrollView` | `LibraryViewController`: `UICollectionView` compositional layout with one orthogonally scrolling section per shelf |
| `SessionCard`, `PlaceholderCard`, `PagePreview` | `SessionCardCell`, `PlaceholderCardCell`; grid drawn with Core Graphics under a `UIImageView` |
| `LectureScreen` | `LectureViewController`: container that shows setup or lecture home, owns name sync and the `UIDocument` state observer |
| `LectureHomeView` | `LectureHomeViewController`: list collection view; rename through `navigationItem.renameDelegate` |
| `SectionSessionsView` (+ add-session sheet) | `SectionSessionsViewController`: list with week headers, scrolls to the current week |
| `MaterialsView`, `MaterialRow`, `DroppedFile` | `MaterialsViewController`: list, `UISearchController`, `UIDocumentPickerViewController`, `UIDropInteraction` |
| `NotebookScreen`, `NotebookHostView` | `NotebookViewController`: bar items, child `NotebookScrollViewController`, optional material pane child and divider |
| `MaterialPane` (+ `PDFKitView`, `QuickLookView` representables) | `MaterialPaneViewController`: `PDFView` or a child `QLPreviewController` |
| `PDFExportSheet` | `PDFExportViewController`: segmented control and thumbnail grid |
| `ShareSheet` representable | `UIActivityViewController` presented directly |
| `MaterialPreviewer` | Already UIKit. Present it from the calling view controller instead of searching for the key window. |
| `LectureSetupView`, `RoutineEditor`, `RoutineSheet`, `LibrarySettingsView` | Hosted for now — Phase 5 |

## Observation

- `LectureLibrary` and `NotebookCoordinator` are `@Observable`. On iOS 26, UIKit tracks
  `@Observable` reads by itself in `updateProperties()`, `viewWillLayoutSubviews()`,
  `layoutSubviews()` and cell configuration update handlers. It re-runs them when something
  they read changes, and no Info.plist key is needed.
- `LectureDocument` is `ObservableObject` with `@Published var manifest`, and UIKit does not
  track that. **Step 0.2 makes it `@Observable`.** What forced `ObservableObject` was
  `ReferenceFileDocument` (it requires `ObservableObject & Sendable`), and that conformance
  went away with `DocumentGroup` on 2026-09-28. Keep it `@MainActor`.
  - Page and thumbnail data stay untracked (`@ObservationIgnored`) for the same reason they
    aren't `@Published` today ([document-format.md](document-format.md) → Autosave design).
  - Each of the four manual `objectWillChange.send()` calls becomes a bump of a tracked counter
    (for example `private(set) var contentRevision`). Readers of page or thumbnail data (session
    rows' "No notes yet", export thumbnails) read that counter so they still refresh.
  - `manifest`'s `didSet { markDirty() }` works the same under `@Observable`.
  - SwiftUI views change from `@ObservedObject var document` to `let document` (or `@Bindable`
    where they need bindings).

## Phases

### Phase 0 — Preparation (still all SwiftUI)

- **0.1** Run the smoke checklist (below) on the baseline and write down anything that already fails,
  so it isn't blamed on the migration later.
- **0.2** `LectureDocument` → `@Observable` (see Observation). Check that every screen still updates:
  session counts, material list, thumbnails after drawing, rename.
- **0.3** Move the route types (`LectureRoute`, `LectureNotebookRoute`, `NotebookRoute`,
  `MaterialsRoute`) out of the views into `Navigation/Routes.swift`. They become `AppCoordinator`'s
  inputs.

### Phase 1 — UIKit shell and navigation

- **1.1 Lifecycle.** Add `@main AppDelegate` and a `SceneDelegate` (returned from
  `application(_:configurationForConnecting:options:)`) whose window root hosts today's
  `LibraryRootView`. `kisacaApp` goes away.
  - `onOpenURL` becomes `scene(_:openURLContexts:)`, plus `connectionOptions.urlContexts` for a
    cold launch from Files.
  - Replace the three `scenePhase` uses (`LibraryRootView`, `LectureScreen`, `NotebookScreen`)
    with `UIScene` notifications (`didActivate` / `willDeactivate` / `didEnterBackground`).
    `scenePhase` isn't reliable without the SwiftUI app lifecycle.
- **1.2 Navigation.** `AppCoordinator` owns a `UINavigationController` and takes over
  `LibraryRootView`: `open`, `createLecture`, import-then-open, and the error alert.
  - Every destination is pushed as a `UIHostingController`.
  - `NavigationLink(value:)` and `.navigationDestination` become closures (`onOpenSection`,
    `onOpenMaterials`, `onOpenNotebook`) that call the coordinator.
  - Card → lecture + notebook becomes a single `setViewControllers`.
  - **`closeAll` when back at the home screen** moves to
    `UINavigationControllerDelegate.navigationController(_:didShow:animated:)`. That call only
    fires for completed transitions, so a cancelled swipe-back does not close anything.
  - Check each hosted screen's `.toolbar` / `.navigationTitle` in the UIKit bar. The renameable
    title (`navigationTitle(Binding)`) is the one most likely not to carry over. If it doesn't,
    move 3.3 earlier.

### Phase 2 — Notebook (most value; its core is already UIKit)

- **2.1** `MaterialPaneViewController`:
  - header: a `UIButton` with a menu of materials, plus add and close buttons
  - `PDFView` for PDFs, a child `QLPreviewController` for anything else
  - picker list and empty state
- **2.2** `NotebookViewController` replaces `NotebookScreen` and `NotebookHostView`.
  - **Bar items.** Leading: pane toggle, add material, add page, page-counter label, delete
    page. Trailing: selected text, export, undo, a "More" menu with Clear Page.
  - **Title** follows `coordinator.currentSessionTitle` for whole-section notebooks, set in
    `updateProperties()`.
  - **Material pane.** Split layout with a divider driven by `UIPanGestureRecognizer`. During
    the drag only a preview line moves; the pane width is applied on release, as today.
  - **Compact width** shows the pane as a sheet instead.
  - Exporting overlay, alerts, and material import through `UIDocumentPickerViewController`.
  - **Autosave timer** starts in `viewWillAppear`, stops and flushes in `viewDidDisappear` and
    on scene deactivate.
  - **`reclaimToolPicker()`** runs in the pane animation's completion instead of after
    today's 400 ms sleep.
  - `NotebookCoordinator` stays as the state object (UIKit observes it). Merging it into the
    view controller can come later.
- **2.3** `PDFExportViewController`: All / Select, a thumbnail grid with checkmarks, then
  `UIActivityViewController`. **On iPad it must get a `popoverPresentationController.sourceItem`
  (the Export bar item) or it crashes.** The SwiftUI sheet hid this.
- **Verify on the iPad at the end of this phase:**
  - Pencil ink persists (the simulator can't show this, see [ARCHITECTURE.md](../ARCHITECTURE.md)).
  - Memory while zoomed stays at the baseline (`phys_footprint`, [notebook-canvas.md](notebook-canvas.md)).
  - The tool picker comes back after the pane opens or closes.

### Phase 3 — Lecture screens

- **3.1** `SectionSessionsViewController`:
  - Whole Notebook row, and a header per week with its date range and "This Week".
  - Scrolls to the current week once, and not when that is the first week.
  - Context-menu delete with an alert that uses today's wording.
  - Add-session sheet with a `UIDatePicker` in a `.medium` detent.
- **3.2** `MaterialsViewController`:
  - Groups for Whole Lecture, then each week.
  - Search, the add menu (Whole Lecture / Week…), and drag-and-drop.
  - Context menu (Rename, Move to, Delete), swipe to delete.
  - Opening shows a progress indicator, then `MaterialPreviewer`.
- **3.3** `LectureHomeViewController`:
  - Materials row, sections with their next-session line and count, empty state.
  - Calendar and add buttons; add-section alert with a text field.
  - Rename through `navigationItem.renameDelegate`, into the same `applyLectureName` funnel.
- **3.4** `LectureViewController` (container):
  - Shows setup (hosted) or lecture home depending on `manifest.needsSetup`, and switches when
    it changes.
  - Takes over from `LectureScreen`: `reconcileNameWithFile`, `applyLectureName`, the
    `UIDocument.stateChangedNotification` observer, `DocumentConflictResolver`, and autosave on
    background.

### Phase 4 — Home screen

- **4.1** `LibraryViewController`:
  - Diffable data source: Upcoming, Last, then one shelf per lecture.
  - Section headers: a `UIButton` with `primaryAction` (open) and a menu (Open / Delete), and
    the `icloud.slash` marker for lectures on this device only.
  - Card context menu, empty state (`UIContentUnavailableConfiguration`), toolbar (Settings,
    Import, New Lecture).
  - Import through `UIDocumentPickerViewController`; delete confirmation as an action sheet
    with a popover source.
- **4.2** Cells:
  - Cells show the grid, the ink thumbnail, the section badge, the "Today" chip and a
    progress indicator while opening.
  - Thumbnails load asynchronously, with a reuse guard. SwiftUI's `.task(id:)` cancelled for
    free; a reused cell must check that it still shows the same item.
  - `ThumbnailCache` and `LectureColor` move over unchanged. `LectureColor` returns a `UIColor`.
- **4.3** Each lecture's shelf opens at the session nearest today. **Risk:** orthogonal sections
  don't expose their scroll view, and `scrollToItem` into one only works after layout. Fallback:
  make each shelf a cell that holds its own horizontal collection view.

### Phase 5 — The forms

- Decide: keep `LectureSetupView`, `RoutineEditor`/`RoutineSheet`, `LibrarySettingsView` and the
  add-session sheet hosted, or rewrite them.
- A rewrite means list-layout collection views with custom cells (date pickers, toggles,
  `UIButton` menus as pickers, dynamic meeting-time rows with swipe to delete).
- Decide after Phase 4, when it is clear what the hosted versions cost in practice.

### Phase 6 — Cleanup and merge

- Delete `NotebookHostView` and the remaining representables. Drop `import SwiftUI` where
  nothing uses it (`LectureDocument` imports it today).
- Update [ARCHITECTURE.md](../ARCHITECTURE.md), [library.md](library.md),
  [notebook-canvas.md](notebook-canvas.md) and [file-map.md](file-map.md).
- Device check, then merge `uikit-migration` into `main`.

## Verification

After every step, build with the command in [build-notes.md](build-notes.md). No new warnings.

**Smoke checklist (simulator)** — run the items the step touched; run all of them at the end of a
phase:

1. Home lists local and iCloud lectures with thumbnails; Upcoming / Last shelves are right.
2. New Lecture → setup → Create: the lecture appears, and the file is renamed to its name.
3. Lecture → section → session → draw → back to home: the card thumbnail is updated.
4. Whole Notebook opens at the latest session; the title follows the page while scrolling.
5. Rename the lecture from its title: the file name follows.
6. Materials: import, open (no Markup button), rename, move to a week, delete, drag and drop.
7. Notebook: add and delete a page, page counter, undo, clear, selected text, export all and
   selected pages → share sheet.
8. Material pane: left and right side, resize, compact width → sheet, the tool picker comes back.
9. Send the app to the background from the notebook: the ink is flushed.
10. Delete a lecture; Settings → Move to iCloud.
11. Open a `.kisaca` from Files, with the app running and from a cold launch.

**On the iPad**, at least at the end of Phases 2 and 4: Pencil ink persists, memory while zoomed,
iCloud sync.

## Risks to watch

| Risk | Where | Guard |
|---|---|---|
| Lectures not saved or closed when returning home | 1.2 | `didShow` on the root, not `willShow`; test cancelled swipe-back |
| Share sheet crash on iPad | 2.3 | popover `sourceItem` |
| Missed UI updates after the `@Observable` switch | 0.2 | revision counter for page and thumbnail data; checklist items 3, 6, 7 |
| Tool picker lost after pane or sheet changes | 2.2 | reclaim in animation completion; checklist item 8 |
| Renameable title not bridged while hosted | 1.2 | move 3.3 earlier if needed |
| Shelf initial position | 4.3 | fallback: nested collection view |
| Cold-launch file open | 1.1 | `connectionOptions.urlContexts`; checklist item 11 |
| Canvas lifecycle regressions | 2.2 | don't change `NotebookScrollViewController`; read [notebook-bug-history.md](notebook-bug-history.md) first |

## Baseline (step 0.1, 2026-09-28, simulator, commit `1b26465`)

Build: clean except one existing warning (`PageCanvasController.swift:332`, `selectedTool`
deprecated in iOS 18 — use `selectedToolItem`).

Passed: 1 (home, shelves, thumbnails), 2 (new lecture → setup → file named after it),
3 (lecture → section → notebook → back; card → notebook → back → lecture → home), 4 (Whole Notebook
opens at the latest session, title "Lectures · …"), 5 (rename from the title menu → file and
`manifest.json` follow), 7 partly (page counter, delete disabled on a one-page session, export all →
share sheet "NumCSE - Lectures", 1.9 MB), 8 partly (pane opens on the left with the PDF, tool picker
stays), 10 (delete lecture).
Not run: 6 (materials import needs the Files picker), 8 resize/compact, 9, 11, and Settings → Move
to iCloud.

Already like this before the migration — don't count as regressions:
- `SectionSessionsView` does not visibly scroll to the current week on open (on iPad week 3 was
  already on screen, so this may just be the list not needing to move).
- The floating tool picker sits over the navigation bar and stays above sheets (Export PDF).
- The delete-lecture confirmation popover points at the navigation bar, not at the shelf header.
- A stroke drawn with simulated touches **was** written to the page file this time (1599 bytes, not
  the 244-byte blank page seen on 2026-09-24).

## Progress

- [x] Phase 0 — preparation (0.1 baseline above; 0.2 `LectureDocument` `@Observable` — `4ce21a4`,
      verified: setup → home switch, add session updates list and counts, "No notes yet" → "1 page"
      after drawing, rename updates the title; 0.3 routes → `Navigation/Routes.swift` — `a30a2e7`)
- [x] Phase 1 — UIKit shell and navigation (`1da6a29`). 1.1 and 1.2 went in as one commit:
      SwiftUI's `onOpenURL` doesn't fire without the SwiftUI app lifecycle, so opening files
      needed the coordinator anyway. Findings:
      - **Windows saved by the SwiftUI app come back black.** Their scene session stores
        `SwiftUI.AppSceneDelegate`, and UIKit only calls `configurationForConnecting` for new
        sessions (also not after a build-number bump). `AppDelegate` destroys those sessions at
        launch and opens a fresh window if none is left. Sessions no longer shown anywhere stay in
        `openSessions` despite the request — they never connect, so they're harmless.
      - Hosted SwiftUI screens carry over into the UIKit bar: `.navigationTitle` (including the
        renameable title and its Rename menu), `.toolbar` groups and `.searchable`.
      - `NavigationLink` rows became `NavigationRow` (button + chevron) — looks the same.
      - Verified (simulator): launch ×3 (stale windows replaced, own window restored), home →
        lecture → section → notebook and back, card → notebook → back → lecture → home, new lecture
        → setup → create, add session, draw, **HOME → page written to disk (item 9)**, back home →
        card thumbnail updated (saved + closed), material pane, Materials with search, Quick Look
        (no Markup), Settings sheet, delete lecture.
      - Not verified: opening a `.kisaca` from Files (item 11 — `simctl openurl` can't open file
        URLs and the simulator's Files doesn't show the library) → check on the iPad, together with
        the black-window fix on a device that had the SwiftUI build.
- [x] Phase 2 — notebook, in the simulator (`448c08a`, `bdcbfc6`). **iPad check still to do**
      (Pencil ink persists, memory while zoomed, the tool picker after the pane — and Phase 1's
      Files open and black-window fix).
      - `NotebookViewController` reads `NotebookCoordinator` in `updateProperties()`: counter, title
        and delete button follow the canvas with no manual observation code.
      - The pane moves between inline and sheet on size-class changes; UIKit folds bar items that
        don't fit into its own "…" menu (titles and enabled state carried over).
      - The coordinator's presentation flags became callbacks (`onPDFReady`, `onSelectedText`).
      - Fixed on the way: the export grid's unchecked circle was invisible (single-layer symbol
        took the white palette colour).
      - Verified (simulator): open (session and whole section, title follows), pane open/close,
        resize + preference stored, add material (document picker opens), add/delete page (with
        confirm), undo, draw → HOME → page on disk, selected-text alert, export all (11 pages) and
        selected (9 pages) → share popover from the Export button, compact window → items in "…",
        pane as sheet → back to inline when widened, back → list shows "1 page".
- [x] Phase 3 — lecture screens, in the simulator (`e49d097`, 2026-09-29).
      - **Plan change: no container.** `LectureScreen`'s logic became `LectureFileSync` (one per open
        lecture, kept by `AppCoordinator`), and when setup is done the coordinator swaps the setup
        form for `LectureHomeViewController` on the stack (cross-fade). A container would have had to
        forward its child's navigation item — setup's "Create" vs. the renameable title.
      - The three lists rebuild their diffable snapshot in `updateProperties()` (reconfiguring every
        item), so they follow the manifest without observation code. `SectionSessions` also reads
        `pageContentRevision` there.
      - **Crash found and fixed:** scrolling to the current week from `viewIsAppearing` asked for a
        header's layout attributes before the collection view had loaded the snapshot
        (`NSInternalInconsistencyException` "… section 3 when there are only 0 sections"). It now
        runs from `viewDidLayoutSubviews`, once `numberOfSections` matches the snapshot.
      - List-identifier enums inside the view controllers need `nonisolated` (MainActor default
        makes their `Hashable` conformance isolated, which diffable data sources reject).
      - Verified (simulator): lecture home (materials summary, next-session lines, counts, title
        menu → Rename), Materials (Quick Look without Markup, search + empty search state, context
        menu), section list scrolls to Week 3 with "This Week", add-session sheet (suggests the next
        meeting), new lecture → setup → Create → swapped to home + file renamed, rename from the
        title → file and manifest follow, add section, add session ("Today", Whole Notebook row
        appears) → delete via context menu + alert, routine sheet, delete the test lecture.
      - Not verified: drag-and-drop import (needs a second app), swipe-to-delete on materials,
        "Move to" a week, adding files through the picker.
- [x] Phase 4 — home screen, in the simulator (`705985e`, 2026-09-30).
      - Header insets: boundary supplementary items already follow the section's content insets,
        so giving the header its own leading inset indented it twice.
      - The shelf-initial-position risk (4.3) didn't materialise: `scrollToItem(at:at: .left)` into
        an orthogonal section works once it runs after a layout pass that holds the snapshot — the
        same guard as the section list. No nested collection view needed.
      - **Found a pre-existing bug and fixed it separately** (`1f5944c`): a deleted lecture came back
        as "This file couldn't be read." — see [library.md → Deleting a lecture](library.md).
      - Verified (simulator): shelves, thumbnails, section badges and colours match the baseline;
        NumCSE's shelf opens at the session nearest today; card → notebook → back → lecture →
        home; placeholder card for a lecture with no sessions; header hold → Open / Delete; the
        delete confirmation points at the header (was the nav bar); delete → shelf gone at once;
        Settings sheet; Import picker (filtered to .kisaca, cancelled).
      - Not verified: the empty-library state (would need the real lectures gone), importing a file,
        a downloading (iCloud-only) lecture's placeholder.
- [x] Phase 5 — forms decision (2026-09-30): **they stay SwiftUI.** They ran unchanged inside
      `UIHostingController`s through Phases 1–4, and a UIKit rewrite would be several hundred lines of
      custom cells for no behaviour change.
- [~] Phase 6 — cleanup and merge.
      - [x] Cleanup (`7fb4e49`): SwiftUI moved to `Forms/` (with Settings), `MaterialPreview` to
        `Lecture/`, stale comments fixed. No representables left; the `import SwiftUI`s in UIKit
        files are the ones that host a form. Build: only the pre-existing `selectedTool` warning.
      - [x] Docs updated (this file, ARCHITECTURE, file-map, library, data-model, …).
      - [ ] **iPad check** (not possible from the simulator): Pencil ink persists; memory while
        zoomed (`phys_footprint`); tool picker after the material pane; opening a `.kisaca` from
        Files (warm and cold); first launch over the SwiftUI build — no black window.
      - [ ] Merge `uikit-migration` into `main` after the iPad check.

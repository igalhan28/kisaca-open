# Notebook canvas

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

> **2026-11-01: the continuous scroll is gone.** The notebook is now one page at a time, turned
> with a Books-style page curl — `NotebookPagerViewController` (a `UIPageViewController`,
> `.pageCurl`) showing `PageCanvasController`s. Each page is one PaperKit canvas the size of the
> screen that fills the width it is given (zoom never below fit-to-width, so no side gaps) and owns
> its own vertical scrolling and pinch zoom, as in Apple's PaperKit template; paper and grid are
> its `contentView`. Fingers turn (sideways swipe, only at fit-to-width), scroll and zoom; the
> Pencil only writes. Turning past the last page adds a page (provisional until the turn
> completes). Why: Pencil latency — see "Pencil latency" at the end. Everything below about the
> parchment scroll view, tiles, canvas windows and zoom commits describes the removed design.

> **Partly stale (noticed 2026-09-23, not rewritten).** This section describes a `UICollectionView`
> / cell-reuse design (`NotebookPageCell`, `didEndDisplaying`, `collectionView`). The code has since
> moved to a plain `UIScrollView` "parchment" with `NotebookPageTileView`s and a small pool of
> `PageCanvasController`s laid over the tiles nearest the viewport — see the header comment of
> `Notebook/NotebookScrollViewController.swift` for the current design and why. The memory principle
> below (live `PaperMarkup`s bounded by what is near the viewport, not by page count) still
> applies; the class and method names do not all exist any more.

The canvas went through three iterations before landing here — Delve's original hand-rolled
`UIScrollView`, then two rebuilds of `NotebookCanvasViewController` — before the user asked for a
true ground-up rebuild ("remove your head of Delve... create those files from the ground up
without ever referring to old notebook files") targeting a specific, named reference: **a
Notability-style continuous vertical scroll, with real memory management** (explicitly contrasted
with Apple's own Notes app, which is also PaperKit-based and known to have memory problems on long
notes). That's what's built now, and it's a genuine rewrite — new files, new types, no code or
structure carried over from any earlier version. The history above is kept only so a future
session doesn't waste time re-discovering why simpler designs (a paged swipe UI, a fixed 3-page
window) were tried and moved past — don't resurrect them without a concrete reason.

## Interaction model

Pages stack vertically and scroll continuously — like Notability, or a long PDF in a document
viewer — not a paged, swipe-one-at-a-time book. Within that, zoom behaves like Photos.app: pinch
into a page and dragging pans around *inside* it instead of scrolling to the next one. The outer
vertical scroll (`UICollectionView.isScrollEnabled`) is disabled for as long as *any* visible page
is zoomed past its fit-to-width size, and re-enabled once every visible page is back at fit —
`NotebookScrollViewController.handleZoomStateChanged` tracks this as a set of currently-zoomed
canvas identities rather than a single flag, since more than one page can be on screen at once.
"At fit" is detected by comparing `PaperMarkupViewController.contentVisibleFrame` (the region of
the A4 page currently on screen) against the full page size with a small tolerance — PaperKit
exposes no direct zoom-scale property, so this is the available proxy; confirmed against the
actual `PaperKit.swiftinterface` in the SDK, not guessed.


## Memory management — the actual design constraint

Built on `UICollectionView`, which comes with cell reuse for free — and that's leaned on for more
than the cell *views*. Each `NotebookPageCell` owns a `PageCanvasController` (a full child view
controller wrapping one live `PaperMarkupViewController`), and that child VC is created **once per
simultaneously-visible cell slot** (typically 2–3 for a single-page-width vertical layout), never
once per page:

- `cellForItemAt` creates a `PageCanvasController` only the first time a given cell instance is
  dequeued; every later reuse of that same cell (for a different page, as the user scrolls) just
  calls `canvas.configure(pageIndex:pageID:markup:)` to repoint the *same* canvas at freshly
  decoded markup for the new page — not a rebuild.
- `didEndDisplaying` is where a page's ink actually gets released: it flushes the outgoing page to
  `LectureDocument` (see [document-format.md → Autosave design](document-format.md)) and detaches the tool picker if that page was
  active. The moment its pooled canvas is later reconfigured for a different page, the old
  `PaperMarkup` has no remaining reference and is gone.

The number of live, decoded `PaperMarkup`s at any moment equals the number of visible cells —
completely independent of how many pages the session actually has. A 500-page session costs the
same live memory as a 5-page one. This is the literal fix for the memory concern that motivated
the rewrite, and it's a standard, well-understood mechanism (`UICollectionView` reuse), not a
custom scheme invented for this app.

**Known follow-up, not yet addressed:** this bounds the *canvas's* memory (per-session, while it's
open). It does **not** address `LectureDocument.pageData` itself holding every page's raw bytes
for *every session in the lecture* resident for the life of the open document —
`ReferenceFileDocument`'s model fundamentally reads the whole package's `FileWrapper` tree up
front (see `init(configuration:)`); there's no supported way to stream pages from a
`DocumentGroup`-backed document lazily after that. For a single session, even a long one, this is
fine (tens to low hundreds of KB per page). It could matter for a lecture that accumulates many
sessions across a whole semester. If that turns out to matter in practice, the fix is architectural
(e.g. one document per session instead of per lecture, or dropping `DocumentGroup` for a custom
`UIDocument`-based implementation) and shouldn't be attempted speculatively — flagged here so it's
not forgotten, not because it's known to be a real problem yet.

## "Active" page (tool picker / first responder)

PaperKit expects exactly one `PaperMarkupViewController` to be the live input target at a time —
attaching the shared `PKToolPicker` to more than one simultaneously risks a tool action (inserting
a shape, etc.) targeting the wrong page. Multiple pages can be visible at once here, so "active" is
tracked explicitly: whichever visible page is closest to the viewport's vertical center becomes
active once scrolling settles (`scrollViewDidEndDecelerating`, a completed drag with no
deceleration, or a completed programmatic scroll) — not continuously during a scroll gesture,
since dragging to scroll and drawing aren't simultaneous actions. The toolbar's page counter, by
contrast, *does* track continuously during scroll (`scrollViewDidScroll`) — it's a cheap geometry
readout, not a tool-picker reassignment, so there's no cost to updating it live.

## Dark mode: dark tool picker, white paper (2026-09-24)

The page is always white paper (`PageCanvasController` sets the PaperKit VC's
`overrideUserInterfaceStyle = .light`), but the shared `PKToolPicker` follows the system, so in
dark mode it is dark — which is wanted, it's what Notes does. The bug was the *colors*: a dark
picker offers swatches adapted for a dark canvas (black shown as white, etc.), while the light
canvas draws their light counterparts, so the swatch the user picked didn't match the ink.
Fix: `toolPicker.colorUserInterfaceStyle = .light` (in `NotebookScrollViewController`) — the
picker's chrome stays dark, its colors are made for the light canvas. This is exactly what
`PKToolPicker.h` documents the property for ("should be set to the canvas's user interface
style"). Don't "fix" this by making the canvas dark: it would invert the paper, not the picker.
Builds clean; **not yet checked on the iPad in dark mode.**

Swiping/scrolling past the last page deliberately does **not** auto-create a new one — only the
explicit "Next" toolbar button does (`scrollToAdjacentPage(direction:)`), which appends via
`PageRepository.appendPage()` only on that deliberate tap.

## Grid: one grid, pixel-snapped (2026-09-24)

Reported: the grid looked blurry. Measured in the simulator (native screenshot, one pixel row):
every grid line was smeared over 3–4 pixels, with a different intensity profile per line. Two
causes. The live canvas's grid was PaperKit's `contentView`, a `draw(_:)` bitmap at A4 size that
PaperKit *magnifies* to the tile's size — blurry at every zoom but 1. And a 5 mm square is almost
never a whole number of pixels, so lines fell between pixels.

Now there is exactly one grid, drawn by the tile (`UIGridBackgroundView`) and never hidden:

- **Layers, not a bitmap.** One solid-colour `CALayer` per line, frame rounded to device pixels,
  width a whole number of pixels (≥ 1). No backing store, so it costs nothing however far the page
  is zoomed.
- **Tiles sit on whole pixels** (`screenPageRect` snaps them) — otherwise Core Animation resamples
  the tile and blurs the snapped lines again.
- **Everything above the grid is transparent ink.** The canvas's `contentView` is a clear view;
  thumbnails are ink-only PNGs (see [document-format.md](document-format.md)). Stacking: white
  paper → grid → thumbnail → canvas.
- **Opaque grid colour** (`PageGeometry.gridColor`), so crossing line layers don't darken.
- **`allowsEdgeAntialiasing` on the line layers.** Without it, mid-pinch (the scroll view shrinks
  the page by a transform) sub-pixel lines were dropped or drawn whole — recorded frames after the
  fingers lift showed missing lines as irregular clusters. At rest it changes nothing.
- **PDF:** ink is rasterised on transparency; the grid is drawn as vector lines
  (`PageRenderer.drawGrid`) under it.

Verified in the simulator: at fit-to-width every line is exactly 1 px, identical intensity, both
axes (before: 3–4 px, varying); zoomed in, every line 3 px, identical; pinch in/out recorded
frame by frame, no missing lines. **Not verified** (needs Apple Pencil): ink over the grid, the
new PNG thumbnails, thumbnail regeneration for old documents, and a PDF export with ink.


## Acting on the user's selection (2026-09-24)

PaperKit's own long-press menu on a selection — the one with **Copy as Text** — is closed.
The whole public API is 330 lines of `PaperKit.swiftinterface`, and the only thing in it
that takes `[UIMenuElement]` is `MarkupEditViewController(supportedFeatureSet:additionalActions:)`,
which is the *insertion* popover, not the selection menu. `PaperMarkupViewController.Delegate`
has no menu-building callback either. Trying to reach it through the responder chain
(`editMenu(for:suggestedActions:)`) doesn't work: the `UIEditMenuInteraction` belongs to
PaperKit's internal view, not to any view controller we own.

So anything we want to do *to* a selection lives on our own toolbar instead, and reads the
selection itself. Two pieces make that work:

- `PaperMarkupViewController.selectedMarkup` is a plain `PaperMarkup` — empty, not `nil`, when
  nothing is selected. `PaperMarkup.hasContent` (in `PageCanvasController.swift`) is the
  emptiness test: an empty markup draws nothing, so `contentsRenderFrame.isEmpty`.
- The live value can't be trusted at the moment a toolbar button is pressed: tapping the nav bar
  resigns first responder on the canvas and PaperKit drops the selection with it, so the handler
  would find nothing every single time. `PageCanvasController` therefore caches the last
  non-empty selection in `paperMarkupViewControllerDidChangeSelection` (previously an empty stub)
  and `currentSelection` prefers the live value, falling back to the cache. The cache is cleared
  in `configure(...)` so a pooled slot never reports the previous page's selection.

Path: `NotebookViewController` bar button → `NotebookCoordinator.showSelectedText()` →
`NotebookScrollViewController.activeSelection` → `PageCanvasController.currentSelection`.

**Open question — does `indexableContent` cover handwriting?** It is documented as extractable
text, and the patterns reference describes it as text *from text boxes*; Notes' "Copy as Text"
comes from handwriting recognition, which may be a different source entirely. Not answerable in
the simulator (no Pencil). The current toolbar button shows the result in an alert and
deliberately reports *which* case it hit (`nil` / empty / actual text, plus the selection frame)
so a single run on a real iPad answers it. If it turns out handwriting isn't covered, the
fallback is to render the selection (`PaperMarkup.draw(in:frame:)`, async — build the `CGContext`
by hand, `UIGraphicsImageRenderer`'s sync closure can't await) and run Vision's handwriting
recognition over the image.

## Pencil-only editing; iPhone read-only (2026-10-31)

Asked for: editing is Apple Pencil only, and no drawing on iPhone.

- `directTouchMode = .selection` already kept a finger from drawing, but a finger could still
  lasso, drag a selection and edit text boxes. PaperKit has no "finger does nothing" mode
  (`TouchMode` is only `.drawing` / `.selection`), so `PageCanvasController.restrictInternalGestures`
  (was `disableInternalZoomGestures`) sets `allowedTouchTypes = [.pencil]` on PaperKit's editing
  recognisers, re-running on selection change since a selection installs its own handle
  recognisers lazily. Since the paged rewrite (2026-11-01) PaperKit's own scroll-view pan/pinch
  stay enabled but finger-only, so the split is: finger scrolls/zooms/turns pages, Pencil writes.
- iPhone (`PageCanvasController.isEditingAvailable`, idiom check): `isEditable = false`, the tool
  picker is never attached, and `NotebookViewController` hides Add/Delete Page, Undo, Clear and
  Selected Text. Material pane, page counter and Export stay.
- **Simulator exception:** the simulator has no Pencil, and its drags arrive as finger touches,
  so in simulator builds (`#if targetEnvironment(simulator)`, `editingTouchTypes`) fingers may
  edit too — otherwise ink could not be smoke-tested there. Device builds are Pencil-only.
  Verified 2026-10-31: a simulated drag draws on the iPad Air 13" simulator.

## Notebook chrome & gestures (2026-11-09)

> **Superseded in part (2026-11-10).** The sidebar, materials, tool disk and tap-to-hide below
> describe the first version. The current chrome — sidebar pinned to a screen edge, applets
> (Materials, Pages), tool **wheel** (`ToolWheelView`), finger **double-tap** to hide, export
> button — is documented in [sidebar.md](sidebar.md). The parts about the hidden system
> picker, edge-zone page turns, the 2× curl and simulator finger ink still apply.

From the user's hand-drawn spec (screenshot of a page, 2026-11-09). What was built first:

- **No navigation bar; a black sidebar instead** (`ToolRailView`, corrected the same day — the
  first version was a floating glass rail plus a corner capsule, which misread the sketch). A
  full-height black strip at the notebook's leading edge, under the status bar: back at the top,
  then the tools, colours (+ colour well), widths, ruler, insert (PaperKit's
  `MarkupEditViewController`: shapes, lines, text box), undo, redo — scrolling if they don't fit —
  and at the bottom the **materials button** (a notebook icon). The tools are drawn pictures
  (`ToolIcons`: pen, fountain pen, pencil, fineliner, highlighter, eraser, lasso) lying with the nib
  towards the page, nib in the tool's ink colour; the tool in hand slides out. Tapping the eraser
  again switches object ↔ pixel. Tool state: `NotebookToolbox` (device-local `UserDefaults`).
- **Materials expand out of the sidebar.** The notebook button slides the material pane out from
  behind the sidebar; layout is [material | sidebar | notebook] (or [sidebar | notebook | divider |
  material] with the pane on the right), so the sidebar's controls stay on the page side. With the
  pane on the left the sidebar is also its resize handle (drag it sideways; the old divider is
  hidden then).
- **Tool disk** (`ToolDiskView`): two-finger sideways swipe anywhere on the page (not while
  zoomed in) opens a half-disc at the bottom: tools outside, colours in the middle, widths
  between undo/redo at the hub; dark like the sidebar, the tool pictures turned nib-outwards.
  Picking a tool closes it; a touch outside (finger or Pencil) closes it without drawing.
- **System tool picker: attached but `.hidden`.** Checked in the simulator: with *no* active
  picker PaperKit is view-only (no ink at all); with `.hidden` it edits and nothing shows.
  PencilKit documents `.hidden` as "active but offscreen", Pencil gestures still work. The page
  is not the picker's observer — `drawingTool` comes from the toolbox — and attaching the picker
  must happen *before* setting `drawingTool` (attaching hands PaperKit the picker's tool). The
  pager observes the picker only to carry the Pencil double-tap (to eraser / back) into the
  toolbox; other picker changes are ignored (attaching announces its default black pen).
- **Page turns only from the edge zones** (`NotebookPagerViewController.turnZone`): strips
  `max(64 pt, 10 %)` of the notebook's width — right turns forward, left back. Swipes only;
  UIKit's tap-to-turn is off. Never with two fingers: the curl pan has
  `maximumNumberOfTouches = 1`, and `TouchCounter` cancels a turn in progress when a second
  finger lands.
- **2× curl.** `UIPageViewController` exposes no duration, so `setTurnSpeed` retimes its view's
  layer (speed 2, clock re-anchored so nothing jumps) for the turn and back to 1 after.
  Measured in the simulator, finger-lift → `didFinishAnimating`: 0.73 / 0.70 s at 1×,
  0.34 / 0.34 s at 2×. Recorded frame by frame: the curl still folds the page over.
- **Tap to hide**: a finger tap anywhere on the page slides the sidebar away (the notebook takes
  its width — one re-fit, so the page scales up slightly) and hides the status bar and home
  indicator (`AppNavigationController` forwards those to the
  top screen). Tap again to bring them back. PaperKit's own finger tap ("Select All" menu) is
  installed when the canvas becomes first responder, so `activate` re-runs
  `restrictInternalGestures` to keep it Pencil-only.
- **Simulator finger ink is opt-in**: launch with `-KisacaFingerInk YES` (e.g.
  `xcrun simctl launch <device> com.igalhan.kisaca -KisacaFingerInk YES`). That also shows the
  system picker — PaperKit lets a finger draw only while one is visible. Without it the
  simulator behaves like the iPad: fingers turn, scroll, tap and open the disk.

**Not verified (needs the iPad + Pencil):** Pencil drawing with the hidden picker, Pencil
double-tap ↔ eraser sync, squeeze (the system's mini palette may appear — it's PencilKit's),
the 2× curl's feel, two-finger cancel of a turn in progress.

## Pencil latency (2026-10-31)

Reported: ink lags the Pencil noticeably more than in Notes, although both use PaperKit.
PencilKit processes Pencil touches on the **main thread**, so any main-thread work while
the user writes delays the stroke. Found and removed (not yet measured on the iPad):

- **Thumbnail render on the main thread after every pause.** `PaperMarkup.draw(in:frame:)`
  is `nonisolated(nonsending)` — it runs on the *caller's* actor — and `PageRenderer` was
  main-actor-bound, so a whole-page render at 2.5× plus a PNG encode ran on the main
  thread 600 ms after each pause in writing, i.e. as the next word began.
  Now: `PageRenderer.renderInk` / `renderThumbnail` are `@concurrent` (render and encode
  off-main), and a live page's thumbnail is only refreshed while it is *visible* (canvas
  windowed, zoomed in). Otherwise it is refreshed on flush (autosave, scroll-away, close).
  A canvas leaving its tile with a stale thumbnail leaves a `snapshotView` behind
  (`NotebookPageTileView.inkPlaceholder`) until the fresh thumbnail lands.
- **Autosave every 8 s whether or not anything changed** — re-encode, `markDirty`, and
  `UIDocument` building the package on the main thread. Now dirty-only
  (`PageCanvasController.hasUnsavedInk`), and the timer skips a tick while a stroke is in
  progress (`isDrawing`, from `didBeginDrawing` → `didChangeMarkup`).
- **`paperVC.markup` read at every stroke end** (delegate). Now read only when needed
  (`currentMarkup`).
- **Outer scroll view accepted Pencil touches** — every stroke began as a contest between
  its pan/pinch and PaperKit's drawing recogniser. Now finger-only, like `PKCanvasView`'s
  `.pencilOnly` policy; `delaysContentTouches = false`. **Behaviour change:** the Pencil no
  longer scrolls the notebook.
- The touch-down recogniser (`reclaimToolPicker`) cancels itself after `.began` instead of
  tracking every move of the stroke.

Second round, zoom and thumbnails (same day):

- **Canvas windowing at ~1 screen** (`wholePageCanvasViewports` 2.5 → 1.2, margin 0.2 → 0.1,
  window slack 1.5 → 1.25): PaperKit's stroke Metal layer is sized to its view, so this
  bounds the per-frame stroke cost. Portrait at fit-to-width still shows the whole page;
  landscape at fit now windows.
- **No thumbnail mask**: the thumbnail around a windowed canvas is four `contentsRect`
  slices (`NotebookPageTileView.thumbnailSlices`) — a mask forced an offscreen pass every
  frame while writing zoomed in.
- **No canvas fade-in**: alpha < 1 composited the canvas (and the stroke layer) offscreen
  for 0.18 s after every pinch/scroll-in. The thumbnail → canvas swap is a hard cut again.
- **Live thumbnails aren't stored**: renders made while writing only update the tile;
  their PNG waits in `unsavedThumbnails` until the page's next flush, so writing doesn't
  trigger `UIDocument` saves.

**Still structurally different from the PaperKit template / Notes** (open decision — see
the session report): several `PaperMarkupViewController`s inside an outer `UIScrollView`,
PaperKit's own scroll/zoom disabled, its view oversized up to 1.5× per side to hide its
margin (so its stroke Metal layer is up to 2.25× the area), and a transparent canvas over
~100 grid line layers per page. Options: keep and measure; one canvas per page with
PaperKit owning zoom (paged); or one canvas per session (Notes-style, file-format change).

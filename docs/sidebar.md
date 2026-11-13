# Notebook sidebar

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

The note-taking screen (`NotebookViewController`) has no navigation bar. Its chrome is
a dark frame: a **sidebar** down one screen edge and a **status strip** across the top.
The sidebar works like Ubuntu's dock: it launches *applets* (panels that slide out
beside the notes) and holds the drawing tools. A two-finger swipe opens the **tool
wheel** for quick switching between recently used tools.

This page describes how that frame is built and how to extend it. Introduced
2026-11-09 → 2026-11-10 on the `sidebar` branch.

## Layout

```
 right-handed (default)                     left-handed
┌───────────────────────────────────┐      ┌───────────────────────────────────┐
│▓▓▓▓▓▓▓▓▓▓▓ status strip ▓▓▓▓▓▓▓▓▓▓│      │▓▓▓▓▓▓▓▓▓▓▓ status strip ▓▓▓▓▓▓▓▓▓▓│
│▓▓│  applet  │┃│    notebook       │      │     notebook      │┃│  applet  │▓▓│
│▓▓│  panel   │┃│                   │      │                   │┃│  panel   │▓▓│
│▓▓│          │┃│                   │      │                   │┃│          │▓▓│
└───────────────────────────────────┘      └───────────────────────────────────┘
 ▓▓ sidebar   ┃ divider (drag to resize the material; a plain line for Pages)
```

- **The sidebar never leaves its screen edge.** It sits on the left, or on the right
  with *Settings → Sidebar → Left-Handed*. These are physical edges, not
  leading/trailing.
- **Applets open next to the sidebar.** Pages always does. Materials does by default;
  *Settings → Material Beside Notes → Opens* can instead put it on the *Opposite Side*.
  This is measured from the sidebar (`MaterialPaneSide.isOnLeft(leftHanded:)`).
- **The status strip** continues the sidebar's black under the status bar across the
  full width. The status bar is always `.lightContent`, so the clock and battery are
  white on black in light and dark mode. `AppNavigationController` forwards
  `childForStatusBarStyle` so that this takes effect.
- **The notebook runs the full height, under the strip,** the way a page runs under a
  navigation bar. Don't move it below the strip. PaperKit insets the page by the safe
  area and needs that inset to fit an A4 page exactly to the width. Without it the
  page is ~3% zoomed in, pans sideways, and `isZoomedIn` turns true, which blocks the
  tool wheel.
- **The applet panel and the divider** start below the status bar.
- **Export button** (`exportItem`): a 44 pt liquid-glass button (`UIButton.Configuration.glass()`,
  forced light style) floating 12 pt inside the notebook's top-right corner, below the status
  bar. It opens `showExportOptions()` and anchors the share sheet's popover. It hides and shows
  with the rest of the chrome. Added back 2026-11-13; the old nav-bar Export item is gone.
- **Hiding the chrome:** a **finger double-tap** on the page slides the sidebar off its
  edge, fades the strip, and hides the status bar and home indicator. Double-tap again
  to bring them back. (It was a single tap, which stray touches triggered too easily.)

All of this layout lives in `NotebookViewController.layoutSplit()`. Its helpers:
- `contentRegion`: everything beside the sidebar.
- `railWidth`: 72 pt, widened by the notch inset on iPhone in landscape.
- `tuckedFrame(_:of:)`: where an applet panel sits while it slides in or out. On the
  sidebar's side that is behind the sidebar; otherwise it is off the far edge.

Z-order, bottom to top: notebook → applet panel → divider → sidebar → status strip →
drag indicator → export button → tool wheel → export overlay. The sidebar sits above the panel, so
the panel slides out from behind it.

## Sidebar anatomy (`ToolRailView`)

From top to bottom:

| Section | What | Scrolls? |
|---|---|---|
| Back | pops the notebook | no |
| Applets | one `AppletButton` per `RailApplet` | no |
| Tools | tool pictures, colour swatches + colour well, widths, ruler, insert | **yes** |
| Pinned | undo, redo | no |

- **The tools section** is a `UIScrollView` inside a clip view. When the tools don't
  fit, it shows an always-visible `RailScrollbar` on the page side, which you can drag
  or tap. A gradient mask fades whichever edge has more content beyond it. When a tool
  becomes the one in hand, it is scrolled into view.
- **`edge` (`.left` / `.right`)** mirrors the sidebar's details:
  - tool pictures get a `scaleX: -1` resting transform, so their tips point into the
    page, and the selected tool slides toward the page;
  - the scrollbar moves to the page side;
  - an open applet's dot moves to the screen-edge side.
- **Horizontally, everything keeps to `safeAreaLayoutGuide`,** so the controls stay
  clear of a notch.
- **The sidebar is always dark** (`overrideUserInterfaceStyle = .dark`, background
  `ToolRailView.backgroundColor`). The tool pictures (`ToolIcons`) are drawn for a dark
  background.

`ToolControls` builds the tool buttons and keeps them in sync with `NotebookToolbox`
(`show(_:canUndo:canRedo:)`). Every tap goes out as a `NotebookToolAction`, which
`NotebookViewController.perform(_:)` applies.

## Extending it

### Applets

An applet is a button in the sidebar plus a panel it opens. Two exist:

| Applet | Panel | Width | Opens |
|---|---|---|---|
| Materials | `MaterialPaneViewController`: course files beside the notes | share of the screen, drag the divider to resize | next to the sidebar, or opposite (setting) |
| Pages | `PageThumbnailsViewController`: every page as a thumbnail; tap to go straight there | fixed, 196 pt | next to the sidebar |

`NotebookViewController` hosts them (*Applet panels* in that file):

- **One panel is open at a time.** Opening another applet slides the open panel away
  while the new one slides out (`placePanel(animated:)`). Tapping the open applet's
  button closes it.
- **Regular width** puts the panel beside the notebook (`inlinePanel`). **Compact
  width** (iPhone, narrow Split View) shows it as a sheet instead (`sheetPanel`). A
  size-class change moves it from one to the other.
- **State:** `openApplet` is what's open. `lastApplet` remembers which side the divider
  should wait on while nothing is open.
- **Sidebar buttons** are built from `Applet.allCases` in `setUpChrome()`.
  `updateProperties()` marks the open one: filled, with a dot, and the `.selected`
  accessibility trait.

### Add an applet

1. Add a case to `Applet` in `NotebookViewController` and give it a `title` and
   `symbol`. The active symbol is `symbol + ".fill"`, so pick an SF Symbol that has a
   fill variant. Set `isResizable` if dragging the divider should resize it.
2. Give it a side in `isOnLeft(_:)` and a width in `width(of:)`.
3. Build its view controller in `makePanel(_:inline:)`:
   - wire its close button to `setOpenApplet(nil)`;
   - for the compact sheet, set its detents there (`inline == false`).
4. If it needs work done before it shows, do it in `setOpenApplet(_:)`. Pages flushes
   the page on screen there, so its thumbnail is current.
5. A resizable applet other than Materials needs its own width preference. Generalise
   `dividerPanned(_:)` for that, since it currently resizes only the material.

The panel itself is an ordinary view controller. Keep it light-weight and let it follow
the notebook through observation: `updateProperties()` reading the
`NotebookCoordinator` and `LectureDocument`, as `PageThumbnailsViewController` does.

### Pages applet (`PageThumbnailsViewController`)

- **Sessions:** a whole-section notebook groups pages under pinned session headers
  ("W3 · Mon"). The groups come from `PageRepository.pageGroups`.
- **Current page:** the page on screen is outlined and kept scrolled into view, and
  "*n* of *N*" sits in the header.
- **Jumping:** tapping a thumbnail calls `NotebookCoordinator.showPage(at:)` →
  `NotebookPagerViewController.showPage(at:)`. That flushes the leaving page and swaps
  pages with no page-curl. As a sheet (compact width), the panel closes after the jump.
- **+** adds a page after the current one, on devices that edit.
- **Thumbnails** are the saved ink-only PNGs drawn over a live grid. They update when a
  page is flushed: on a turn, a jump, an autosave, and when the panel opens. Decoded
  images are cached with their bytes, so an unchanged tile doesn't flash.

### Add a tool action (a sidebar button that does something)

1. Add a case to `NotebookToolAction` (`ToolRailView.swift`).
2. Create the button in `ToolControls.init` with its local `button(symbol, label,
   action)` helper, and reflect its state in `ToolControls.show`.
3. Add it to a group in `ToolRailView.init`:
   - `groups` for the scrolling section (separators are inserted between groups);
   - `pinnedStack` only if it must never scroll away.
4. Handle it in `NotebookViewController.perform(_:)`.

### Add a drawing tool

1. Add a case to `NotebookToolKind`, with `title`, `symbolName` and `inkType`.
2. Draw its picture in `ToolIcons.image(for:ink:...)`. It is 58 × 24 pt, tip to the
   right, on a dark background.
3. It appears in the sidebar automatically: buttons are built from
   `NotebookToolKind.allCases`. Add a case for it in the `ToolCombo ==` and
   `ToolCombo.title` switches if it doesn't behave like ink.

## Tool wheel (`ToolWheelView`)

The tool wheel is a quick switcher modelled on an iPod click wheel.

- **Gesture:** `TwoFingerSwipeRecognizer` begins when both fingers move sideways
  together by 14 pt or more. It fails on a pinch (finger spread changes by more than
  36 pt), a vertical scroll, a third finger, or one finger already dragging. It only
  watches: other recognisers keep their touches.
- **While zoomed in,** it doesn't begin (`gestureRecognizerShouldBegin`). Two fingers
  pan the page then.
- **Turning:** the wheel turns with the fingers, one notch per 64 pt
  (`pointsPerNotch`), with a `UISelectionFeedbackGenerator` tick at each notch.
  Swiping left brings up the combination clockwise of the pointer, which is the one
  used most recently before the current one.
- **Lifting the fingers** takes up the combination under the pointer
  (`NotebookToolbox.apply`). Ending where you started changes nothing.
- **It never takes touches** (`isUserInteractionEnabled = false`), so it can't get in
  the Pencil's way.

### What it shows: `NotebookToolbox.wheelCombos`

- The tool in hand (`currentCombo`) comes first.
- Then `recentCombos`, most recent first, up to `recentLimit` (8).
- If fewer than `wheelMinimum` (4), the list is topped up with `starterCombos`.

A `ToolCombo` is a tool kind, a colour (inking tools only), a width level, and the
eraser kind. "Recent" means **written with**, not just picked:
`PageCanvasController.onBeginDrawing` → pager → `toolbox.noteCurrentToolUsed()`.
That call saves but deliberately doesn't notify observers: re-handing the tool to
PaperKit mid-stroke would break the stroke. Choosing a combination on the wheel also
records it. Recents persist with the rest of the toolbox in `UserDefaults`
(`notebookToolbox`).

## Preferences (`AppPreferences`)

| Key | Type | Meaning |
|---|---|---|
| `leftHanded` | Bool | sidebar on the right edge |
| `materialPaneSide` | `MaterialPaneSide` raw | `"leading"` = next to sidebar, `"trailing"` = opposite (raw values kept from the old left/right setting) |
| `materialPaneFraction` | Double | material width as a share of the screen width (0.25–0.65) |

The open applet itself isn't saved; every notebook opens with none.

The notebook reads these on every layout pass. Changes made in Settings apply the next
time the notebook appears.

## Pitfalls we hit

- **Swapping one applet panel for another:** the new panel must be laid out at its
  final size and only then moved to its tucked frame, with the old panel still in
  place, before the animation runs (`placePanel`). Otherwise the notebook and divider
  jump instead of sliding.
- **Notebook below the status strip** makes PaperKit zoom in. See *Layout* above.
- **Dynamic colours inside `UIGraphicsImageRenderer`:** `.label` resolves outside the
  sidebar's dark trait and came out black on black. Use explicit colours in drawn
  images (`swatchImage`, `ToolIcons`).
- **Scrollbar showing with nothing to scroll:** the scroll view measures its content
  in its own layout pass, after the sidebar's. `ToolRailView.layoutSubviews` calls
  `scrollView.layoutIfNeeded()` before reading `contentSize`.
- **Mid-stroke tool changes:** never notify toolbox observers from
  `onBeginDrawing`.

## Testing in the simulator

```bash
# finger draws, so ink can be tested without a Pencil
xcrun simctl launch booted com.igalhan.kisaca -KisacaFingerInk YES
```

```bash
# toggle left-handed without going through Settings
xcrun simctl spawn booted defaults write com.igalhan.kisaca leftHanded -bool YES
```

- **Tool wheel:** use a two-finger touch path moving sideways; about 64 pt equals one
  notch.
- **Scrollbar:** rotate to landscape on an 11" iPad; the tools overflow there.

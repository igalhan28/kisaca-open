# Notebook canvas — verification gaps & bug history

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

## Not yet verified

Builds clean and launches without crashing in the simulator (`xcodebuild` + `simctl launch`, both
re-run after this rewrite). What's **not** verified from this environment: actual scroll feel,
pinch-to-zoom-then-pan handoff, and Apple Pencil input — none of that can be scripted here (no
touch/gesture synthesis available), so it needs a hands-on pass in Xcode or on a device. If the
zoom gating feels early/late, the tolerance constant in `PageCanvasController` is the place to
adjust; if cell recycling ever looks visually wrong (a page briefly showing another page's stale
content while scrolling fast), that points at the `cellForItemAt` reuse branch.

**This gap is not hypothetical — it already caused a shipped crash once.** The user hit
`Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value` at
`NotebookScrollViewController.swift:175` (inside `mostVisibleCanvas()`, reading `collectionView`)
the first time they actually opened a notebook, despite this environment's launch-only smoke test
reporting a clean run — because that test never navigates past the document browser, so it never
touched this code path at all. Root cause: `viewDidLoad` assigned `cv.dataSource`/`cv.delegate`
and then set `cv.contentInset`, and setting `contentInset` synchronously fired
`scrollViewDidScroll` — which reads `self.collectionView`, an implicitly-unwrapped optional not
yet assigned at that point (the assignment came after, at the end of the setup block). Fixed by
assigning `collectionView = cv` immediately after creating it, before `dataSource`/`delegate`/
`contentInset`/`addSubview`/anything else that could trigger a callback. The same "delegate wired
before the property its callbacks read is assigned" pattern existed in
`PageCanvasController.viewDidLoad` too (`vc.delegate = self` before `paperVC = vc`) — it wasn't
actually reachable there since those delegate methods use their own parameter rather than
`self.paperVC`, but it was fixed to the same safe ordering anyway rather than left relying on that
staying true. **Lesson for next time:** wherever a view controller stores something in an IUO
property (`X!`) and then hands out its `delegate`/`dataSource` to itself, assign the property
*before* wiring the delegate, full stop — don't assume nothing will fire synchronously.

**Second bug found the same way (user testing, not this environment): vertical scrolling was
completely locked from the moment a notebook opened.** Root cause was in
`PageCanvasController.fitA4InViewport` — it computed its own scale + centering *origin* offset
before calling `setContentVisibleFrame`, math ported forward from Delve's canvas without
re-deriving whether it still made sense. It didn't: Delve fit an A4 page into a full screen of a
*different* aspect ratio and needed to compute where to center it; here, each collection view
cell is already sized to A4's own aspect ratio (`NotebookScrollViewController.updateItemSize`), so
there's nothing left to center. Passing a non-zero origin while still requesting the *full page
size* asked PaperKit for a region that didn't line up with what was actually on screen, so
`contentVisibleFrame` read back slightly off a full page on every layout — which both looked
visibly wrong (the "pages on different components" / cropped-looking pages the user reported) and
fed into the zoom-gating check: comparing that slightly-off size against the full page size with a
tight ~1pt tolerance meant every page looked "zoomed in" the instant it appeared, permanently
setting `collectionView.isScrollEnabled = false`. Two independent-looking symptoms, one cause.

Fixed by (1) simplifying `fitA4InViewport` to just request the full page unconditionally — no
manual scale/origin math, since the cell's aspect ratio already matches — and (2) making the
zoom-fit check itself more robust regardless: it now compares *area ratio* against an 85%
threshold instead of near-exact point equality, so it takes a real, deliberate zoom rather than
any small layout/rounding noise to trip it. Also added a defensive clear in
`configureCanvas` so a pooled canvas slot that was ever marked "zoomed" can't carry that flag into
whatever page it gets recycled for next, even if some other case flips `isAtFitZoom` without
re-triggering the change callback. **Lesson for next time:** don't carry geometry math forward
from a different layout context (full-screen vs. a fixed-aspect-ratio cell) just because it
compiled and "probably still applies" — re-derive it for the new context, and prefer a threshold
with real margin (area ratio, not ~1pt) whenever a comparison feeds something as consequential as
"is scrolling allowed."

**Third bug (user testing): closing a notebook crashed the app** with
`UIViewControllerHierarchyInconsistency` ("child view controller: PageCanvasController should have
parent view controller:(null) but actual parent is: NotebookScrollViewController"). Chain:
`NotebookScreen.onDisappear` (since the UIKit migration: `NotebookViewController.viewDidDisappear`) → `flushActivePage()` → `PageCanvasController.renderSnapshot()` →
`drawHierarchy(in:afterScreenUpdates: true)`. By `onDisappear` the canvas view has already left the
window, and `drawHierarchy` on an off-window view makes UIKit move it into a temporary window to
render it — which fails UIKit's containment check because that view belongs to a child VC. Fixed by
having `renderSnapshot()` return `nil` when `view.window == nil` (the flush then saves markup only
and keeps the existing thumbnail, which `viewWillDisappear`'s flush already refreshed while still on
screen), and by switching to `afterScreenUpdates: false` (the page is already rendered; `true` is
also rejected inside a Core Animation commit, e.g. during a navigation transition, and silently
yields a blank image). Verified in the simulator: open notebook → draw → back no longer crashes.
**Lesson for next time:** never snapshot a child VC's view unless it is in a window.

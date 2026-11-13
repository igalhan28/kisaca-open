# Zoom commits and the thumbnail ↔ canvas swap (2026-09-23)

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

Reported symptom: pinching in or out produced a brief jarring transition as pages went from
thumbnail to live canvas, *except* when the pinch happened to be centred. Two changes, one
measured and one reasoned:

1. **The swap itself is a hard cut, and that is the visible part.** Crossing
   `liveEditScaleFraction` replaced a tile's cached thumbnail with a live PaperKit canvas in a
   single frame — a resolution jump, landing exactly where the user is looking, at the same
   moment the page is changing size. `NotebookPageTileView.attach(_:animated:)` now crossfades:
   the grid goes at once (the canvas draws its own), the thumbnail stays underneath and the
   canvas fades in over it in 0.18s. Verified that the two renderings are *positionally*
   identical first — cross-correlating the thumbnail-state page against the canvas-state page
   over a 60×85 ink grid gives a best alignment shift of exactly (0, 0), so there is nothing to
   fix there and a crossfade cannot smear. A single threshold also meant a pinch settling near
   it swapped every visible page back and forth, so release now happens at a lower one
   (`liveEditReleaseFraction`).

2. **`commitZoom` no longer reconstructs the scroll offset.** It used to read the document point
   at the viewport centre, then recompute an offset that re-centres it. Those are the same thing
   only for a centred pinch; anywhere else the round trip goes through one point and drops where
   the gesture actually left the page. Carrying the offset across directly is exact — the content
   is the same size before and after (old `scale` × gesture zoom = new `scale`) — and it only
   needs a scale factor for a pinch that hit `minScale`/`maxScale`. The conversions either side
   of it (`viewportCenterInDocument`, `contentOffset(centering:)`) also used `bounds`' geometric
   midpoint while clamping against `adjustedContentInset`; they now share one `visibleCenterInBounds`.
   **Honest scope:** with an off-centre no-op pinch in the simulator the *old* code already
   held position to the pixel (safe-area insets are 0 in this layout, and clamping hides the
   rest at fit-to-width), so this one is correctness, not a reproduced fix. Item 1 is the one
   that was demonstrably visible.

Verified in the simulator: pinch out to thumbnail → pinch back in to a live canvas, off-centre
both ways, leaves the page correctly positioned with its ink intact, and an off-centre no-op
pinch is pixel-identical before and after.

**3. The jump is at the moment the finger lifts — measured from an iPad recording (2026-09-23).**
The user pointed out that the shift happens between the last frame with the fingers down and the
first one after, worst going from a middling zoom to very close; neither of the two changes above
targets that, and the simulator never reproduced it. A screen recording from the iPad (old build)
settles it. Extracting the frames and fitting a scale + translation between each consecutive pair
finds, at 7.800 → 7.817s, a **pure translation of ~26px (≈13pt) with scale exactly 1.00, fitting
93% of the frame difference** — immediately after which the screen is completely still. Sampling
ink-only and grid-only pixels separately in three bands down the page gives the same shift for
both (+25 to +28px, no relative displacement), so the page, its grid and its ink all moved
together: this is the scroll view's content offset, not PaperKit re-rendering its ink.

That is a correction being applied in one frame. A pinch can end with the content outside the
scroll view's limits — rubber-banded past an edge, or zoomed past `maxScale` — and `UIScrollView`
eases that back itself; committing the geometry (`zoomScale` → 1, new `contentSize`) cancels that
animation and applies the whole correction instantly. `commitZoom` now writes the carried offset
through *unclamped* and animates to the clamped one (`settle(from:)`, 0.25s ease-out). A
temporary `print` reports the correction in points whenever one happens.

**Not yet verified on device.** The simulator does not reproduce the jump (no correction is ever
owed there), so this is reasoned from the measurement, not from a fixed before/after. Next session:
run on the iPad, repeat the medium → very close off-centre pinch, and read the
`kisaca: zoom commit settled by (…)` lines. If they appear and the jump is gone, this was it and
the `print` can go. If the jump remains with no such line, the correction is coming from somewhere
else and the next suspect is PaperKit's re-render at the new tile size
(`PageCanvasController.fitA4InViewport`) — though the ink-vs-grid measurement above argues against it.

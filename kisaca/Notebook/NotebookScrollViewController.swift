//
//  NotebookScrollViewController.swift
//  kisaca
//
//  A Preview.app-style continuous document view: every page of one session stacked
//  vertically on a single scrollable, zoomable "parchment".
//
//  ## Why a plain UIScrollView and not a UICollectionView
//  Zoom is the whole point of this screen's feel, and `UIScrollView`'s own zoom
//  (pinch, rubber-band at the limits, momentum, simultaneous pan) is very hard to
//  reproduce convincingly by hand. A collection view can only be zoomed by
//  recomputing its layout on every gesture frame, which is both expensive and
//  janky. So the scroll view owns zoom, and page recycling — which a collection
//  view would otherwise give us for free — is hand-rolled below. It's a small
//  amount of bookkeeping for a much better-feeling gesture.
//
//  ## Document space vs. screen space
//  Layout is defined in "document points": a page is literally 595×842, with fixed
//  gaps and margins around it. `scale` maps that to screen points. Because gaps and
//  margins are scaled by the *same* factor as the pages, zooming grows the whole
//  sheet uniformly, like a PDF viewer — rather than magnifying ink inside a
//  fixed-size frame, which is what made the previous per-page zoom feel wrong.
//
//  ## Memory — the actual design constraint
//  A page is in one of three states, and only the first one costs real memory:
//    1. Live   — a pooled `PageCanvasController` with decoded `PaperMarkup`.
//    2. Tile   — a `NotebookPageTileView`: white paper, grid, cached thumbnail.
//    3. Absent — not materialised at all.
//  At most `canvasPoolSize` canvases ever exist, and below `liveEditScaleFraction`
//  of fit-to-width *none* do: zoomed that far out the user is surveying pages, not
//  writing on them, so everything stays a cheap thumbnail. That second bound is
//  what stops a zoomed-out view — where many pages are on screen at once — from
//  demanding many live canvases. A 500-page session costs the same as a 5-page one.
//
//  ## "Active" page (tool picker / first responder)
//  PaperKit expects exactly one `PaperMarkupViewController` to hold the tool picker
//  at a time. Several canvases can be live at once here, so "active" is tracked
//  explicitly: whichever live page is nearest the viewport's vertical centre,
//  reassigned once scrolling settles rather than continuously mid-gesture. The page
//  counter is pure geometry, so that *does* update continuously.
//

import PaperKit
import PencilKit
import UIKit

@MainActor
final class NotebookScrollViewController: UIViewController {

    // MARK: - Document-space layout constants

    private static let docGap: CGFloat = 24
    private static let docMargin: CGFloat = 24

    /// Live canvases are only handed out at or above this fraction of fit-to-width.
    private static let liveEditScaleFraction: CGFloat = 0.6

    /// …and only taken back below this lower one. The gap is deliberate: with a
    /// single threshold, a pinch that settles near it — or drifts across it twice
    /// on the way somewhere else — swaps every visible page between thumbnail and
    /// live canvas each time, which reads as a flicker.
    private static let liveEditReleaseFraction: CGFloat = 0.45

    /// Hard ceiling on simultaneously live `PageCanvasController`s.
    private static let canvasPoolSize = 3

    /// A live canvas covers its whole page only while that page is at most this many
    /// viewports in area; beyond, it covers just the visible part — see
    /// `PageCanvasController.visiblePageRect` for why that is the memory bound.
    /// Around fit-to-width a page is under this, so ordinary use never windows.
    private static let wholePageCanvasViewports: CGFloat = 2.5

    /// How far past the viewport's edges, as a fraction of the viewport, a canvas
    /// window reaches — so it doesn't have to move with every point of scrolling.
    private static let canvasWindowMargin: CGFloat = 0.2

    // MARK: - Dependencies

    private let repository: PageRepository
    weak var coordinator: NotebookCoordinator?

    /// Page to open at instead of the first — a whole-section notebook opens at its
    /// latest session, not at week 1. Read once, at the first layout.
    var initialPageIndex: Int?

    // MARK: - Views
    //
    // All `let` stored properties rather than implicitly-unwrapped optionals — the
    // old implementation crashed because a delegate callback fired while an IUO
    // `collectionView` was still nil. That whole class of bug is gone by
    // construction here: these are never nil at any point.

    private let scrollView = UIScrollView()
    private let parchmentView = UIView()
    /// The picker's own chrome follows the system (dark in dark mode, like Notes), but its
    /// colors are made for the canvas, which is always light — white paper, see
    /// `PageCanvasController`. Without `colorUserInterfaceStyle` a dark picker offers
    /// dark-adapted swatches (black shows as white) that then draw as their light
    /// counterparts on the page, so the swatch and the ink don't match.
    private let toolPicker: PKToolPicker = {
        let picker = PKToolPicker()
        picker.colorUserInterfaceStyle = .light
        return picker
    }()

    // MARK: - State

    /// Document points → screen points.
    private var scale: CGFloat = 1
    private var lastFitScale: CGFloat = 1
    private var hasPerformedInitialLayout = false

    private var tiles: [Int: NotebookPageTileView] = [:]
    private var canvasPool: [PageCanvasController] = []
    private weak var activeCanvas: PageCanvasController?

    /// Suppresses delegate reactions while we rewrite the scroll view's geometry.
    private var isCommittingZoom = false

    /// Whether pages are currently eligible for live canvases at all. Stateful
    /// because the thresholds that raise and lower it differ — see
    /// `liveEditReleaseFraction`.
    private var canvasesAreLive = false

    // MARK: - Init

    init(repository: PageRepository, coordinator: NotebookCoordinator) {
        self.repository = repository
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        // Fingers scroll and zoom; the Pencil only ever writes. Left at their defaults
        // the scroll view's pan and pinch also accept Pencil touches, so every stroke
        // starts as a contest between them and PaperKit's drawing recogniser — and a
        // stroke that moves first along the scroll axis can be taken as a scroll.
        // `PKCanvasView` does exactly this for its own scroll view under its
        // `.pencilOnly` drawing policy. The pinch recogniser only exists once zooming
        // is possible, so `rebuildGeometry` restricts that one.
        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        // Gesture recognisers see touches at once either way; this only stops the
        // scroll view holding back `touchesBegan` from the views inside it for its
        // ~150 ms "is this a scroll?" wait.
        scrollView.delaysContentTouches = false
        scrollView.contentInsetAdjustmentBehavior = .always
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        scrollView.addSubview(parchmentView)

        // Any touch on the notebook takes the tool picker back if something else took
        // first responder — see `reclaimToolPicker()`. Zero-duration, simultaneous and
        // non-cancelling, so scrolling, pinching and drawing all still get the touch.
        let touchDown = UILongPressGestureRecognizer(
            target: self, action: #selector(notebookTouched(_:)))
        touchDown.minimumPressDuration = 0
        touchDown.cancelsTouchesInView = false
        touchDown.delaysTouchesBegan = false
        touchDown.delaysTouchesEnded = false
        touchDown.delegate = self
        view.addGestureRecognizer(touchDown)

        coordinator?.currentPageIndex = 0
        coordinator?.totalPages = repository.pageCount
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }

        let fit = fitToWidthScale
        let previousScale = scale
        // Read before `scale` moves: on a rotation or split-view resize the fit
        // scale changes, and keeping the raw offset would slide the page by
        // whatever that change happened to be worth.
        let anchor = hasPerformedInitialLayout ? viewportCenterInDocument : nil
        let isInitialLayout = !hasPerformedInitialLayout

        if !hasPerformedInitialLayout {
            hasPerformedInitialLayout = true
            scale = fit
        } else if forcesFitWidth || abs(scale - lastFitScale) < 0.001 {
            // Was sitting exactly at fit-to-width; stay there across a rotation or
            // split-view resize instead of drifting to an arbitrary zoom.
            scale = fit
        }
        lastFitScale = fit

        // `contentOffset(centering:)` reads the new `scale`, so it is computed here
        // rather than alongside the anchor above.
        var restored = anchor.flatMap { anchor in
            scale != previousScale ? contentOffset(centering: anchor) : nil
        }
        if isInitialLayout, let index = initialPageIndex, index > 0, index < repository.pageCount {
            // The page's top edge (and the gap above it) just under the navigation bar.
            restored = CGPoint(
                x: scrollView.contentOffset.x,
                y: screenPageRect(at: index).minY - Self.docGap * scale
                    - scrollView.adjustedContentInset.top)
        }
        rebuildGeometry(restoringOffset: restored)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateActiveCanvas()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushActivePage()
    }

    // MARK: - Geometry

    private var docContentSize: CGSize {
        let count = max(repository.pageCount, 1)
        let height =
            2 * Self.docMargin
            + CGFloat(count) * PageGeometry.a4Size.height
            + CGFloat(count - 1) * Self.docGap
        return CGSize(width: PageGeometry.a4Size.width + 2 * Self.docMargin, height: height)
    }

    private var scaledContentSize: CGSize {
        CGSize(width: docContentSize.width * scale, height: docContentSize.height * scale)
    }

    private var fitToWidthScale: CGFloat {
        guard scrollView.bounds.width > 0 else { return 1 }
        return scrollView.bounds.width / docContentSize.width
    }

    /// The "Always Fit Page to Width" preference. Pinning both zoom limits to fit
    /// is all it takes: the scroll view then has no room to pinch, and every layout
    /// pass snaps `scale` back to fit.
    private var forcesFitWidth: Bool {
        UserDefaults.standard.bool(forKey: AppPreferences.Key.notebookFitsWidth)
    }

    private var minScale: CGFloat { fitToWidthScale * (forcesFitWidth ? 1 : 0.35) }
    private var maxScale: CGFloat { fitToWidthScale * (forcesFitWidth ? 1 : 4) }

    private func docPageRect(at index: Int) -> CGRect {
        CGRect(
            x: Self.docMargin,
            y: Self.docMargin + CGFloat(index) * (PageGeometry.a4Size.height + Self.docGap),
            width: PageGeometry.a4Size.width,
            height: PageGeometry.a4Size.height)
    }

    /// Snapped to whole device pixels. The page grid is drawn pixel-exact *within*
    /// its tile (`UIGridBackgroundView`), which only lands on real pixels if the tile
    /// itself starts on one; a fractional origin would have Core Animation resample
    /// the whole tile and blur every line again. Moves a page by under half a pixel.
    private func screenPageRect(at index: Int) -> CGRect {
        let rect = docPageRect(at: index).applying(CGAffineTransform(scaleX: scale, y: scale))
        let pixels = max(view.traitCollection.displayScale, 1)
        func snap(_ value: CGFloat) -> CGFloat { (value * pixels).rounded() / pixels }
        let minX = snap(rect.minX)
        let minY = snap(rect.minY)
        return CGRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
    }

    /// The middle of what the user actually sees, in scroll-view bounds coordinates.
    /// Not `bounds`' own midpoint: with `.always` inset adjustment the scroll view
    /// extends under the navigation bar and the home indicator, so the visual centre
    /// sits below the geometric one by half the difference between those insets.
    /// Using the geometric midpoint here and the adjusted insets when clamping is
    /// what used to make a zoom commit shift the page by a few points.
    private var visibleCenterInBounds: CGPoint {
        let inset = scrollView.adjustedContentInset
        return CGPoint(
            x: (inset.left + scrollView.bounds.width - inset.right) / 2,
            y: (inset.top + scrollView.bounds.height - inset.bottom) / 2)
    }

    /// The document-space point currently at the centre of the viewport. Accounts
    /// for any in-flight gesture zoom, since `contentOffset` lives in zoomed space.
    private var viewportCenterInDocument: CGPoint {
        let z = max(scrollView.zoomScale, 0.0001)
        let divisor = max(scale * z, 0.0001)
        let centre = visibleCenterInBounds
        return CGPoint(
            x: (scrollView.contentOffset.x + centre.x) / divisor,
            y: (scrollView.contentOffset.y + centre.y) / divisor)
    }

    /// Clamps an offset to what the scroll view would actually allow at rest — the
    /// inverse of `viewportCenterInDocument`'s conversion is otherwise free to land
    /// outside the scrollable range and snap once UIKit takes over.
    private func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(scaledContentSize.width - scrollView.bounds.width + inset.right, minX)
        let maxY = max(scaledContentSize.height - scrollView.bounds.height + inset.bottom, minY)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY))
    }

    private func contentOffset(centering doc: CGPoint) -> CGPoint {
        let centre = visibleCenterInBounds
        return clampedContentOffset(
            CGPoint(x: doc.x * scale - centre.x, y: doc.y * scale - centre.y))
    }

    /// Keeps the parchment centred whenever it is smaller than the viewport —
    /// otherwise zooming out leaves the document jammed against the top-left with
    /// dead space beside it, instead of sitting in the middle the way a PDF viewer
    /// would. Reads `parchmentView.frame`, not `scaledContentSize`, because during a
    /// pinch the scroll view is scaling the parchment by transform and only the
    /// frame reflects that in-flight size.
    private func centerContent() {
        let content = parchmentView.frame.size
        let insetX = max((scrollView.bounds.width - content.width) / 2, 0)
        let insetY = max((scrollView.bounds.height - content.height) / 2, 0)
        let centering = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if scrollView.contentInset != centering {
            scrollView.contentInset = centering
        }
    }

    /// Writes `scale` into the scroll view's real geometry and re-tiles. Gesture
    /// zoom is always reset to 1 here: `scale` is the single source of truth, and
    /// `zoomScale` is only ever a transient multiplier on top of it during a pinch.
    /// `clampOffset: false` writes the offset through even when it sits outside the
    /// scroll view's limits — used by `commitZoom`, which then eases it back rather
    /// than letting the rebuild teleport it there.
    private func rebuildGeometry(restoringOffset offset: CGPoint?, clampOffset: Bool = true) {
        isCommittingZoom = true
        defer { isCommittingZoom = false }

        if scrollView.zoomScale != 1 {
            scrollView.zoomScale = 1
        }
        parchmentView.frame = CGRect(origin: .zero, size: scaledContentSize)
        scrollView.contentSize = scaledContentSize
        scrollView.minimumZoomScale = minScale / scale
        scrollView.maximumZoomScale = maxScale / scale
        // With the zoom pinned, a pinch would otherwise still rubber-band.
        scrollView.bouncesZoom = !forcesFitWidth
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        // Before restoring the offset, not after — the offset clamp reads the insets
        // this sets.
        centerContent()
        if let offset {
            scrollView.contentOffset = clampOffset ? clampedContentOffset(offset) : offset
        }

        refreshTiles()
        updatePageCounter()
    }

    /// Folds a finished pinch into `scale`, resetting the gesture's own `zoomScale`
    /// to 1 so that pages re-render crisply at the new size instead of staying
    /// transform-magnified.
    ///
    /// The offset is carried over **directly**, not recomputed from the document
    /// point at the viewport centre. The two are the same thing only for a pinch
    /// that happened to be centred; anywhere else the round trip through a single
    /// centre point discards where the gesture actually left the page, and the
    /// commit yanked it back to centre — the jarring flick on any off-centre pinch.
    /// Carried over directly it is exact: the content is the same size before and
    /// after (old `scale` × gesture zoom = new `scale`), so the same offset shows the
    /// same thing, and `factor` is 1 in every case except a pinch that ran into
    /// `minScale`/`maxScale`. There it anchors the visible centre, which is the only
    /// sensible reading of a gesture the limits refused to follow.
    private func commitZoom(gestureScale: CGFloat) {
        let effectiveScale = scale * scrollView.zoomScale
        let target = min(max(scale * gestureScale, minScale), maxScale)
        let factor = target / max(effectiveScale, 0.0001)
        let anchor = visibleCenterInBounds
        let offset = scrollView.contentOffset

        let carried = CGPoint(
            x: (offset.x + anchor.x) * factor - anchor.x,
            y: (offset.y + anchor.y) * factor - anchor.y)

        scale = target
        // Deliberately unclamped — see `settle(from:)`.
        rebuildGeometry(restoringOffset: carried, clampOffset: false)
        settle(from: carried)
        updateActiveCanvas()
    }

    /// Eases the content back inside the scroll view's limits after a zoom commit,
    /// instead of snapping it there.
    ///
    /// A pinch can end with the content outside those limits — rubber-banded past an
    /// edge, or zoomed beyond `maxScale` — and `UIScrollView` would normally ease it
    /// back itself. Committing the geometry (`zoomScale` → 1, new `contentSize`)
    /// cancels that, and whatever correction was owed is applied in the single frame
    /// the finger lifts. Measured on an iPad recording of the old behaviour: the
    /// page, its grid and its ink all jumped ~13pt sideways together, in one frame,
    /// with no change of scale, right as the gesture ended — the reported "jarring"
    /// transition. So the correction is animated here, on the same easing curve a
    /// scroll view's own bounce uses.
    private func settle(from carried: CGPoint) {
        let settled = clampedContentOffset(carried)
        let dx = settled.x - carried.x, dy = settled.y - carried.y
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        print(String(format: "kisaca: zoom commit settled by (%.1f, %.1f)pt", dx, dy))
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
            animations: { self.scrollView.contentOffset = settled })
    }

    // MARK: - Tiling

    private var visibleIndexRange: Range<Int> {
        let count = repository.pageCount
        guard count > 0 else { return 0..<0 }
        let z = max(scrollView.zoomScale, 0.0001)
        let divisor = max(scale * z, 0.0001)
        let minY = scrollView.contentOffset.y / divisor
        let maxY = (scrollView.contentOffset.y + scrollView.bounds.height) / divisor
        let step = PageGeometry.a4Size.height + Self.docGap

        // One page of slack either side, so a tile is ready before it scrolls in.
        let first = Int(floor((minY - Self.docMargin) / step)) - 1
        let last = Int(floor((maxY - Self.docMargin) / step)) + 1
        let lower = min(max(first, 0), count)
        let upper = min(max(last + 1, lower), count)
        return lower..<upper
    }

    private func refreshTiles() {
        let range = visibleIndexRange

        for (index, tile) in tiles where !range.contains(index) {
            if let canvas = tile.canvas {
                flush(canvas)
                releaseCanvas(canvas, from: tile)
            }
            tile.removeFromSuperview()
            tiles[index] = nil
        }

        for index in range {
            let tile = tiles[index] ?? makeTile(at: index)
            tile.frame = screenPageRect(at: index)
            // Every pass, not just at creation: a page inserted above shifts which
            // session owns this index.
            tile.gridSpacing = repository.gridSpacing(forPageAt: index)
        }

        updateCanvasAssignments()
        updateCanvasWindows()
    }

    /// What of the parchment the viewport shows, grown by `canvasWindowMargin` —
    /// the region a canvas window has to cover. In scroll-view content coordinates.
    private var canvasWindowRegion: CGRect {
        let visible = scrollView.bounds
        return visible.insetBy(
            dx: -visible.width * Self.canvasWindowMargin,
            dy: -visible.height * Self.canvasWindowMargin)
    }

    /// Sizes each live canvas to its page, or — once a page is too big on screen —
    /// to the part of it inside `canvasWindowRegion`. A window is kept while it still
    /// covers everything visible and isn't much bigger than needed, so ordinary
    /// scrolling moves it only every so often.
    private func updateCanvasWindows() {
        let visible = scrollView.bounds
        let region = canvasWindowRegion
        let viewportArea = visible.width * visible.height
        for tile in tiles.values where tile.canvas != nil {
            let pageScale = tile.bounds.width / PageGeometry.a4Size.width
            guard pageScale > 0, viewportArea > 0 else { continue }
            let pageArea = tile.bounds.width * tile.bounds.height
            guard pageArea > viewportArea * Self.wholePageCanvasViewports else {
                tile.canvasWindow = nil
                continue
            }
            // Ink written while the canvas covered the whole page never reached the
            // thumbnail (see `scheduleThumbnailRefresh`), and from here on the
            // thumbnail is what shows outside the window.
            if tile.canvasWindow == nil, let canvas = tile.canvas {
                refreshThumbnail(for: canvas)
            }
            let toPage = CGAffineTransform(scaleX: 1 / pageScale, y: 1 / pageScale)
            func inPage(_ rect: CGRect) -> CGRect {
                scrollView.convert(rect, to: tile).applying(toPage)
                    .intersection(PageGeometry.a4Bounds)
            }
            let needed = inPage(visible)
            let wanted = inPage(region)
            guard !wanted.isNull, !wanted.isEmpty else { continue }
            if let current = tile.canvasWindow,
                needed.isNull || current.contains(needed),
                current.width * current.height <= wanted.width * wanted.height * 1.5
            {
                continue
            }
            tile.canvasWindow = wanted
        }
    }

    private func makeTile(at index: Int) -> NotebookPageTileView {
        let tile = NotebookPageTileView(frame: screenPageRect(at: index))
        if index < repository.pageIDs.count {
            let pageID = repository.pageIDs[index]
            tile.thumbnail = repository.loadThumbnail(for: pageID)
            if tile.thumbnail == nil { regenerateThumbnail(forPageAt: index, pageID: pageID) }
        }
        parchmentView.addSubview(tile)
        tiles[index] = tile
        return tile
    }

    /// Page IDs with a thumbnail render in flight, so a tile recreated while one is
    /// running doesn't start a second.
    private var regeneratingThumbnails: Set<UUID> = []

    /// A page with ink but no thumbnail — one saved before thumbnails became ink-only
    /// PNGs, see `LectureDocument.thumbnailData` — would otherwise look blank whenever
    /// it has no live canvas. Renders one from the markup and shows it, unless the tile
    /// got one of its own (a live snapshot) in the meantime.
    private func regenerateThumbnail(forPageAt index: Int, pageID: UUID) {
        guard regeneratingThumbnails.insert(pageID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            let image = await repository.regenerateThumbnail(forPageAt: index)
            regeneratingThumbnails.remove(pageID)
            guard let image, let tile = tiles[index], tile.thumbnail == nil,
                index < repository.pageIDs.count, repository.pageIDs[index] == pageID
            else { return }
            tile.thumbnail = image
        }
    }

    /// Decides which visible tiles deserve a live, editable canvas — the memory
    /// bound described in the type doc.
    private func updateCanvasAssignments() {
        let fit = fitToWidthScale
        canvasesAreLive =
            canvasesAreLive
            ? scale >= fit * Self.liveEditReleaseFraction
            : scale >= fit * Self.liveEditScaleFraction

        var eligible: Set<Int> = []
        if canvasesAreLive {
            let centerY = viewportCenterInDocument.y
            // A page wholly outside the region would get a canvas window of nothing.
            let region = canvasWindowRegion
            let ranked = tiles.keys.filter { tiles[$0]?.frame.intersects(region) == true }.sorted {
                abs(docPageRect(at: $0).midY - centerY) < abs(docPageRect(at: $1).midY - centerY)
            }
            eligible = Set(ranked.prefix(Self.canvasPoolSize))
        }

        // Reclaim canvases from tiles that no longer qualify. Flushing first is the
        // equivalent of the old `didEndDisplaying` save — nothing drawn is lost.
        for (index, tile) in tiles where !eligible.contains(index) {
            guard let canvas = tile.canvas else { continue }
            flush(canvas)
            releaseCanvas(canvas, from: tile)
        }

        // Hand canvases to tiles that just became eligible.
        for index in eligible.sorted() {
            guard let tile = tiles[index], tile.canvas == nil,
                index < repository.pageIDs.count
            else { continue }
            let canvas = dequeueCanvas(into: tile, animated: hasPerformedInitialLayout)
            canvas.configure(
                pageIndex: index,
                pageID: repository.pageIDs[index],
                markup: repository.loadMarkup(forPageAt: index))
        }
    }

    // MARK: - Canvas pool
    //
    // Pooled canvases stay child view controllers for this controller's whole life;
    // only their *views* move between tiles. That keeps containment bookkeeping to a
    // single addChild per canvas, and there are never more than `canvasPoolSize`.

    /// `animated` crossfades the tile's thumbnail into the live canvas — see
    /// `NotebookPageTileView.attach`. Off for the very first assignment, where
    /// there is nothing on screen yet to fade from.
    private func dequeueCanvas(into tile: NotebookPageTileView, animated: Bool)
        -> PageCanvasController
    {
        if let recycled = canvasPool.popLast() {
            tile.attach(recycled, animated: animated)
            return recycled
        }
        let canvas = PageCanvasController()
        canvas.onInkChanged = { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.scheduleThumbnailRefresh(for: canvas)
        }
        addChild(canvas)
        tile.attach(canvas, animated: animated)
        canvas.didMove(toParent: self)
        return canvas
    }

    private func releaseCanvas(_ canvas: PageCanvasController, from tile: NotebookPageTileView) {
        if canvas === activeCanvas {
            canvas.detachToolPicker(toolPicker)
            activeCanvas = nil
        }
        // `flush` runs first and starts the thumbnail render, so a stale thumbnail
        // means one is on its way; until it lands, a snapshot stands in.
        let thumbnailIsStale =
            canvas.needsThumbnail
            || canvas.pageID.map { renderingThumbnails.contains($0) } == true
        tile.detachCanvas(keepingInk: thumbnailIsStale)
        canvasPool.append(canvas)
    }

    // MARK: - Active page / tool picker

    private func updateActiveCanvas() {
        let centerY = viewportCenterInDocument.y
        let nearest =
            tiles
            .compactMap { index, tile in tile.canvas.map { (index: index, canvas: $0) } }
            .min {
                abs(docPageRect(at: $0.index).midY - centerY)
                    < abs(docPageRect(at: $1.index).midY - centerY)
            }?
            .canvas

        guard nearest !== activeCanvas else { return }
        activeCanvas?.detachToolPicker(toolPicker)
        activeCanvas = nearest
        nearest?.attachToolPicker(toolPicker)
    }

    /// Gives the tool picker back to the active page when something else took first
    /// responder from it. The picker's visibility follows the first responder, and
    /// `updateActiveCanvas` only reassigns it when the *page* changes — so before this,
    /// opening the material pane (its PDF view takes first responder) hid the picker for
    /// good: no tools, and in the simulator touches scrolled instead of drawing.
    func reclaimToolPicker() {
        guard let canvas = activeCanvas else {
            updateActiveCanvas()
            return
        }
        guard !canvas.canvasIsFirstResponder else { return }
        canvas.attachToolPicker(toolPicker)
    }

    /// Only the touch-down matters. The recogniser is then cancelled — toggling
    /// `isEnabled` does that — so it doesn't keep tracking, and calling back for, every
    /// move of a stroke. It doesn't cancel touches in the view, so nothing else
    /// notices.
    @objc private func notebookTouched(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began else { return }
        reclaimToolPicker()
        recognizer.isEnabled = false
        recognizer.isEnabled = true
    }

    private func updatePageCounter() {
        let step = PageGeometry.a4Size.height + Self.docGap
        let index = Int(floor((viewportCenterInDocument.y - Self.docMargin) / step))
        let current = min(max(index, 0), max(repository.pageCount - 1, 0))
        coordinator?.currentPageIndex = current
        coordinator?.totalPages = repository.pageCount
        coordinator?.canDeleteCurrentPage = repository.canRemovePage(at: current)
        let title = repository.sessionTitle(forPageAt: current)
        if coordinator?.currentSessionTitle != title { coordinator?.currentSessionTitle = title }
        let sessionID = repository.session(forPageAt: current)?.id
        if coordinator?.currentSessionID != sessionID { coordinator?.currentSessionID = sessionID }
    }

    // MARK: - Save / thumbnail

    /// Hands the canvas's ink to the repository if it changed since the last flush,
    /// and refreshes its thumbnail if that is stale. A page nobody wrote on costs
    /// nothing.
    private func flush(_ canvas: PageCanvasController) {
        guard let pageID = canvas.pageID else { return }
        if canvas.hasUnsavedInk, let markup = canvas.currentMarkup {
            canvas.hasUnsavedInk = false
            repository.saveMarkup(markup, forPageID: pageID)
        }
        refreshThumbnail(for: canvas)
    }

    /// Re-renders the page's thumbnail if its ink changed since the last one, stores
    /// it, and shows it on the page's tile. Addressed by page ID — the render finishes
    /// later, when the canvas may already show another page.
    private func refreshThumbnail(for canvas: PageCanvasController) {
        guard canvas.needsThumbnail, let pageID = canvas.pageID else { return }
        canvas.needsThumbnail = false
        renderingThumbnails.insert(pageID)
        Task { [weak self] in
            let thumbnail = await canvas.renderThumbnail()
            guard let self else { return }
            renderingThumbnails.remove(pageID)
            let tile = repository.pageIDs.firstIndex(of: pageID).flatMap { self.tiles[$0] }
            guard let thumbnail else {
                tile?.removeInkPlaceholder()
                return
            }
            repository.saveThumbnail(png: thumbnail.png, for: pageID)
            tile?.thumbnail = thumbnail.image
        }
    }

    private var pendingThumbnailRefreshes: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Pages whose ink is being rendered into a thumbnail right now.
    private var renderingThumbnails: Set<UUID> = []

    /// Keeps the thumbnail no more than a moment behind the ink — but only while it
    /// can be seen. Zoomed in, the thumbnail is what shows outside the canvas's window,
    /// so ink written a moment ago has to be in it before that part of the page can
    /// scroll out of the window. At ordinary zoom the canvas covers the whole page and
    /// the thumbnail is hidden under it: re-rendering it after every pause in writing
    /// was pure cost, landing just as the next word began. Those pages get their
    /// thumbnail when they are flushed (autosave, scrolling away, closing).
    /// Debounced: rendering after every stroke of a fast-writing hand is wasted work.
    private func scheduleThumbnailRefresh(for canvas: PageCanvasController) {
        guard let index = canvas.pageIndex, tiles[index]?.canvasWindow != nil else { return }
        let key = ObjectIdentifier(canvas)
        pendingThumbnailRefreshes[key]?.cancel()
        pendingThumbnailRefreshes[key] = Task { [weak self, weak canvas] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, let canvas else { return }
            pendingThumbnailRefreshes[key] = nil
            refreshThumbnail(for: canvas)
        }
    }

    /// Called by the coordinator's autosave timer, on scene backgrounding, and
    /// before PDF export. Pages that scrolled away are already flushed as they went.
    func flushActivePage() {
        guard let canvas = activeCanvas else { return }
        flush(canvas)
    }

    /// The autosave timer's flush: same as `flushActivePage`, except that it never
    /// runs in the middle of a stroke — the next tick picks the page up instead.
    func autosaveActivePage() {
        guard let canvas = activeCanvas, !canvas.isDrawing else { return }
        flush(canvas)
    }

    var activeMarkup: PaperMarkup? { activeCanvas?.currentMarkup }

    /// The selection on the page that currently holds the tool picker, or `nil` when
    /// nothing is selected there. Only the active canvas is consulted: it is the only
    /// one the user can be interacting with.
    var activeSelection: PaperMarkup? { activeCanvas?.currentSelection }

    // MARK: - Public interface (toolbar)

    /// Inserts a blank page after the current one and scrolls to it. Deliberate action
    /// only — never created by scroll position.
    func addPage() {
        let current = coordinator?.currentPageIndex ?? 0
        guard let new = repository.insertPage(after: current) else { return }
        remapTiles { $0 > current ? $0 + 1 : $0 }
        rebuildGeometry(restoringOffset: nil)
        scrollToPage(new)
    }

    /// Deletes the current page and its ink; what was below it takes its place on
    /// screen. The last page of a session stays — see `PageRepository.canRemovePage`.
    func deleteCurrentPage() {
        let index = coordinator?.currentPageIndex ?? 0
        guard repository.canRemovePage(at: index) else { return }

        // No flush for this page's canvas: its ink is about to be deleted.
        if let tile = tiles[index] {
            if let canvas = tile.canvas { releaseCanvas(canvas, from: tile) }
            tile.removeFromSuperview()
            tiles[index] = nil
        }
        repository.removePage(at: index)
        remapTiles { $0 > index ? $0 - 1 : $0 }
        // Same offset, not `nil`: the content just got shorter, and if this was the
        // last page the offset has to come back inside it.
        rebuildGeometry(restoringOffset: scrollView.contentOffset)
        updateActiveCanvas()
    }

    /// Re-keys the tiles — and tells the canvases laid over them — after pages were
    /// inserted or removed: `newIndex` gives a page's index once the change is made.
    /// Nothing is reloaded; a page keeps its tile, thumbnail and live canvas, and
    /// `refreshTiles()` afterwards only has to place them.
    private func remapTiles(_ newIndex: (Int) -> Int) {
        var remapped: [Int: NotebookPageTileView] = [:]
        for (index, tile) in tiles {
            let new = newIndex(index)
            remapped[new] = tile
            tile.canvas?.updatePageIndex(new)
        }
        tiles = remapped
    }

    private func scrollToPage(_ index: Int) {
        guard index >= 0, index < repository.pageCount else { return }
        let rect = screenPageRect(at: index)
        let maxY = max(scaledContentSize.height - scrollView.bounds.height, 0)
        let y = min(max(rect.midY - scrollView.bounds.height / 2, 0), maxY)
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: y), animated: true)
    }

    func clearActivePage() {
        activeCanvas?.clear()
    }

    func undoActivePage() {
        activeCanvas?.undo()
    }
}

// MARK: - UIScrollViewDelegate

@MainActor
extension NotebookScrollViewController: UIScrollViewDelegate {

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { parchmentView }

    /// Fires continuously through a pinch, so the parchment stays centred while the
    /// gesture is in flight rather than snapping into place only once it ends.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isCommittingZoom else { return }
        centerContent()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isCommittingZoom else { return }
        updatePageCounter()
        // Mid-pinch the parchment is only transform-scaled; re-tiling against a
        // transform that's about to be thrown away would both fight the gesture and
        // waste work. Tiles are rebuilt once the zoom settles, in `commitZoom`.
        guard !scrollView.isZooming else { return }
        refreshTiles()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
    ) {
        commitZoom(gestureScale: scale)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateActiveCanvas()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updateActiveCanvas() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateActiveCanvas()
    }
}

// MARK: - UIGestureRecognizerDelegate

@MainActor
extension NotebookScrollViewController: UIGestureRecognizerDelegate {
    /// The touch-down recognizer only observes; it must never keep scrolling, zooming or
    /// PaperKit's drawing from seeing the same touch.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

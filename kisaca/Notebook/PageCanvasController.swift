//
//  PageCanvasController.swift
//  kisaca
//
//  One "slot" of live PaperKit canvas. `NotebookScrollViewController` creates a small,
//  fixed pool of these — one per simultaneously-visible collection view cell, plus a
//  couple of buffer slots — NOT one per page. As the user scrolls, a slot gets
//  `configure(pageIndex:pageID:markup:)`'d to a different page instead of being torn
//  down and rebuilt; this is standard `UICollectionViewCell`-reuse-style pooling,
//  applied to a full child view controller. It's what makes memory bounded: the
//  number of live `PaperMarkupViewController`s (and decoded `PaperMarkup`s) equals
//  the size of this pool, never the number of pages in the session.
//

import PaperKit
import PencilKit
import UIKit

@MainActor
final class PageCanvasController: UIViewController {

    /// Whether pages can be written on at all. Not on iPhone: there is no Apple Pencil
    /// for it, and the notebook is pencil-only (see `restrictInternalGestures`), so an
    /// iPhone shows the notes read-only — no tool picker, no editing.
    static let isEditingAvailable = UIDevice.current.userInterfaceIdiom != .phone

    /// The touches that may edit a page. Apple Pencil only — except in the simulator,
    /// which has no Pencil: there a mouse drag arrives as a finger touch, and without it
    /// ink could not be smoke-tested at all (docs/notebook-canvas.md).
    private static let editingTouchTypes: [NSNumber] = {
        #if targetEnvironment(simulator)
            [UITouch.TouchType.pencil, .direct].map { NSNumber(value: $0.rawValue) }
        #else
            [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        #endif
    }()

    /// `nil` until the first `configure(...)` call.
    private(set) var pageIndex: Int?
    private(set) var pageID: UUID?

    private var paperVC: PaperMarkupViewController!

    /// Markup points per page point for the page this slot shows — 1 for pages from
    /// before `PageGeometry.inkScale`. `visiblePageRect` is in page points; PaperKit is
    /// told the same rectangle in markup points.
    private var inkScale: CGFloat = PageGeometry.inkScale

    /// The markup of whatever page this slot currently shows.
    ///
    /// Read on demand — when saving, rendering a thumbnail or exporting — not copied
    /// out after every stroke. The getter hands back a whole-page value built from
    /// PaperKit's live model, and the delegate callback that used to read it fires on
    /// the main thread at the end of every stroke, which is right when the next one is
    /// about to start.
    var currentMarkup: PaperMarkup? { paperVC.markup }

    /// Whether the ink changed since it was last handed to the repository. Lets the
    /// autosave timer skip a page nobody touched — before, every tick re-encoded the
    /// page and marked the document dirty, so `UIDocument` wrote the package every few
    /// seconds while the user wrote.
    var hasUnsavedInk = false

    /// When the stroke in progress began, `nil` between strokes. PaperKit reports a
    /// stroke's start (`didBeginDrawing`) and, once it is committed, a markup change.
    private var strokeBeganAt: Date?

    /// Whether the pencil is on the page right now — periodic work (the autosave
    /// flush) waits for the stroke to end instead of competing with it for the main
    /// thread. Times out, so a stroke whose end PaperKit never reports can't hold
    /// autosave off for good.
    var isDrawing: Bool {
        guard let began = strokeBeganAt else { return false }
        return Date().timeIntervalSince(began) < 10
    }

    /// The last selection that actually contained something, kept because the live
    /// `paperVC.selectedMarkup` can be cleared out from under us: tapping a toolbar
    /// button resigns first responder on the canvas, and PaperKit drops the selection
    /// with it. Reading only the live value would therefore make a "do something with
    /// the selection" button find nothing every time it is pressed. Reset in
    /// `configure(...)` so a pooled slot never reports the previous page's selection.
    private var lastNonEmptySelection: PaperMarkup?

    /// Whether the ink changed since the last thumbnail was taken. The autosave timer
    /// flushes every few seconds; re-rendering and PNG-encoding an unchanged page each
    /// time is pure CPU.
    var needsThumbnail = false

    /// Called after every change to the ink — the owner uses it to keep the tile's
    /// thumbnail fresh, since outside `visiblePageRect` that thumbnail is what shows.
    var onInkChanged: (() -> Void)?

    /// The part of the page this canvas shows, in page points — its view is laid over
    /// exactly that part of the tile. The whole page at ordinary zoom; zoomed in, only
    /// what is on screen (plus a margin).
    ///
    /// This is the memory bound for PaperKit itself. PaperKit sizes several of its own
    /// layers to its view — two overlay backing stores and a triple-buffered Metal
    /// layer for the stroke in progress — so a view the size of a whole zoomed page
    /// costs whole-page bitmaps at that zoom. Measured on an iPad Air 13" at 6× fit:
    /// the page view was 7584×10732 pt, each overlay layer ~1.2 GB, each Metal
    /// drawable ~720 MB, and the app was killed at ~2.9 GB. Showing only a window of
    /// the page keeps all of that screen-sized whatever the zoom.
    var visiblePageRect: CGRect = PageGeometry.a4Bounds {
        didSet {
            guard visiblePageRect != oldValue, isViewLoaded else { return }
            fitPassesForCurrentSize = 0
            view.setNeedsLayout()
            fitA4InViewport(animated: false)
            restrictInternalGestures()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Transparent so the tile's white sheet shows through anywhere PaperKit
        // hasn't drawn — a page that falls a few points short of its slot then reads
        // as page margin instead of a hole.
        view.backgroundColor = .clear
        // `sizePaperVCToFillPage` deliberately makes the PaperKit view larger than
        // this one to cancel out PaperKit's internal margin; clipping is what keeps
        // that overflow off the neighbouring pages.
        view.clipsToBounds = true

        // Starts blank; the caller always calls `configure(...)` in the same run
        // loop turn before this is ever actually displayed, so there's no visible
        // flash of blank content.
        let vc = PaperMarkupViewController(
            markup: .blankPage(), supportedFeatureSet: .latest)
        // Deliberately wide, and NOT user-facing zoom. `zoomRange` is the range of
        // scales PaperKit is allowed to render its content at — and making a 595pt
        // page fill a tile that is currently, say, 2400pt wide *is* a 4x render
        // scale. Pinning this to 1.0 (an earlier attempt at "turn the internal zoom
        // gesture off") therefore didn't disable a gesture at all: it forced the
        // page to draw at literally 595×842 inside whatever size tile it was given,
        // so the page stayed a fixed size while everything around it scaled.
        //
        // The bounds have to cover the whole range the outer scroll view can impose:
        // fit-to-width varies from roughly 0.6 (iPhone) to 2.1 (large iPad), and the
        // scroll view allows 0.35x–4x of that.
        vc.zoomRange = 0.1...16.0
        // Finger doesn't draw — it scrolls and pinches, like every PDF viewer and
        // like Notability. Drawing is Apple Pencil's job. Without this the outer
        // scroll view would be fighting PaperKit for every touch. `.selection` alone
        // still lets a finger select and move ink; `restrictInternalGestures` takes
        // that away too, so editing of any kind is Pencil only.
        vc.directTouchMode = .selection
        vc.directTouchAutomaticallyDraws = false
        vc.isEditable = Self.isEditingAvailable
        vc.overrideUserInterfaceStyle = .light  // Page is always white paper — fixes the loupe background.

        // Transparent: the paper and its grid belong to the tile underneath
        // (`NotebookPageTileView`), which draws the grid pixel-snapped at whatever
        // size the page is shown. The grid used to live here, and PaperKit magnifies
        // its content view as a bitmap — that is what made it blurry. This view is
        // kept only to give PaperKit its page-sized content.
        let page = UIView(frame: PageGeometry.newMarkupBounds)
        page.backgroundColor = .clear
        page.isUserInteractionEnabled = false
        vc.contentView = page

        // `paperVC` (an implicitly-unwrapped optional) is assigned before `delegate`
        // is set and before addChild/addSubview/didMove — the same ordering fix as
        // `NotebookScrollViewController.viewDidLoad`. Its delegate callbacks below
        // happen to only use their own parameter rather than `self.paperVC`, so this
        // wasn't actually reachable as a crash, but getting the ordering right here
        // too avoids relying on that staying true as the delegate methods change.
        paperVC = vc
        vc.delegate = self
        // `.clear`, not a static color: this view fills the same bounds as `view`
        // above and would otherwise paint over it. `view`'s own `.systemBackground`
        // (unforced) is what actually shows in the margin PaperKit reserves around
        // `contentView` — see the comment on `view.backgroundColor` above.
        vc.view.backgroundColor = .clear
        // Pin the default ink explicitly rather than trust PaperKit's own ambient
        // default-tool selection: that default appears to key off the *tool
        // picker's* trait (dark picker → defaults to a light/white ink), not the
        // paper's, which on this always-white page made fresh strokes invisible by
        // default the moment the tool picker was allowed to follow system Dark Mode.
        // `PKInkingTool`'s own `color:` parameter defaults to `.black` — pinning it
        // here just makes that the guaranteed behavior instead of an implicit one.
        vc.drawingTool = PKInkingTool(.pen, color: .black)
        addChild(vc)
        view.addSubview(vc.view)
        vc.view.frame = view.bounds
        vc.didMove(toParent: self)
        restrictInternalGestures()
    }

    /// The size `sizePaperVCToFillPage` last settled against, and how many passes it
    /// has taken since. See the budget check in `viewDidLayoutSubviews`.
    private var lastFittedSize: CGSize = .zero
    private var fitPassesForCurrentSize = 0

    /// Re-entrancy guard for `fitA4InViewport`: `setContentVisibleFrame` can call the
    /// delegate back, and the delegate asks for a fit.
    private var isApplyingVisibleFrame = false

    /// At most this many fit passes per size the tile hands us.
    ///
    /// `sizePaperVCToFillPage` reads `contentVisibleFrame` and writes the PaperKit
    /// view's size; PaperKit then recomputes `contentVisibleFrame` from that size.
    /// Each write schedules another layout pass, so the two only stop if they
    /// converge — and if they ever land on two values further apart than the
    /// tolerance, they ping-pong through layout for ever with the main thread pegged.
    /// That is the shape of the intermittent freeze reported under fast repeated
    /// pinching, where tiles are resized many times a second. A budget makes
    /// non-convergence cost a slightly mis-sized page for one gesture instead of a
    /// hang; it resets the moment the tile's size actually changes, so normal
    /// resizing is unaffected.
    private static let maximumFitPasses = 4

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if view.bounds.size != lastFittedSize {
            lastFittedSize = view.bounds.size
            fitPassesForCurrentSize = 0
        }
        guard fitPassesForCurrentSize < Self.maximumFitPasses else {
            if fitPassesForCurrentSize == Self.maximumFitPasses {
                fitPassesForCurrentSize += 1  // report once per size, not per pass
                print("kisaca: page fit did not converge at \(view.bounds.size) — budget spent")
            }
            return
        }
        fitPassesForCurrentSize += 1

        sizePaperVCToFillPage()
        fitA4InViewport(animated: false)
    }

    /// PaperKit keeps a margin around `contentView` — it will not let the page reach
    /// the edge of its own view. Left alone that draws the page smaller than the
    /// slot it was given, so the page sits visibly inset inside its own tile.
    ///
    /// `contentVisibleFrame` reports how much of the document is actually on screen,
    /// so comparing it against the page size gives the factor by which PaperKit
    /// shrank things. Oversizing this view by that same factor puts the page back on
    /// `view.bounds` exactly; the tile's container clips, so the overflow can't reach
    /// neighbouring pages.
    ///
    /// The tolerance guard is load-bearing, not politeness: applying a new size
    /// triggers another layout pass, so if PaperKit's margin is a fixed number of
    /// points rather than a fixed fraction, an ungated version of this would chase
    /// its own tail forever.
    private func sizePaperVCToFillPage() {
        guard let paperVC, view.bounds.width > 0, view.bounds.height > 0 else { return }

        let visible = paperVC.contentVisibleFrame
        let overshoot =
            visible.width > 0
            ? min(max(visible.width / (visiblePageRect.width * inkScale), 1), 1.5)
            : 1
        let target = CGSize(
            width: view.bounds.width * overshoot,
            height: view.bounds.height * overshoot)

        guard abs(paperVC.view.bounds.width - target.width) > 0.5
            || abs(paperVC.view.bounds.height - target.height) > 0.5
        else { return }

        paperVC.view.bounds = CGRect(origin: .zero, size: target)
        paperVC.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    /// A wide `zoomRange` is needed so PaperKit *renders* the page at whatever size
    /// its tile currently is — but it also arms PaperKit's own pinch handling, which
    /// would then fight the outer scroll view for the same gesture. Zoom belongs to
    /// the scroll view here, so PaperKit's pinch recognisers are switched off.
    ///
    /// Its internal scroll views stop scrolling too. While the canvas showed the whole
    /// page there was nothing for them to scroll; once it shows only a window of a
    /// zoomed page (`visiblePageRect`) there is, and they took every finger pan —
    /// scrolling the page *inside* the canvas instead of the notebook.
    ///
    /// Every other recogniser — drawing, lasso, tapping or dragging a selection,
    /// editing a text box — is limited to Apple Pencil. `directTouchMode` has no "finger
    /// does nothing" setting (only `.drawing` or `.selection`), so this is what makes
    /// editing Pencil-only: a finger touch never reaches PaperKit and goes to the outer
    /// scroll view, which scrolls and zooms.
    ///
    /// These are ordinary public `UIGestureRecognizer` and `UIScrollView` objects
    /// reached through the view hierarchy; no private API is touched. If some future
    /// PaperKit stops installing them, this finds none and quietly does nothing.
    private func restrictInternalGestures() {
        let editingTouchTypes = Self.editingTouchTypes
        func restrict(in root: UIView) {
            for recognizer in root.gestureRecognizers ?? [] {
                if recognizer is UIPinchGestureRecognizer {
                    recognizer.isEnabled = false
                } else if recognizer.allowedTouchTypes != editingTouchTypes {
                    recognizer.allowedTouchTypes = editingTouchTypes
                }
            }
            if let scrollView = root as? UIScrollView, scrollView.isScrollEnabled {
                scrollView.isScrollEnabled = false
            }
            root.subviews.forEach(restrict)
        }
        guard let paperVC else { return }
        restrict(in: paperVC.view)
    }

    // MARK: - Configure (reuse entry point)

    /// Repoints this slot at a different page.
    func configure(pageIndex: Int, pageID: UUID, markup: PaperMarkup) {
        self.pageIndex = pageIndex
        self.pageID = pageID
        show(markup)
        lastNonEmptySelection = nil
        needsThumbnail = false
        hasUnsavedInk = false
        strokeBeganAt = nil
        // A pooled canvas is often handed a tile of exactly the size it just left, so
        // the budget below would still be spent from the previous page and this one
        // would never get its fit passes.
        fitPassesForCurrentSize = 0
        fitA4InViewport(animated: false)
        // Recognisers can be installed lazily, so re-run this whenever the slot is
        // repointed rather than trusting the single pass in `viewDidLoad`.
        restrictInternalGestures()
    }

    /// Hands `markup` to PaperKit along with its coordinate space: old and new pages
    /// differ in size (see `PageGeometry.inkScale`), and a pooled slot shows both.
    private func show(_ markup: PaperMarkup) {
        paperVC.markup = markup
        inkScale = markup.inkScale
        paperVC.contentView?.frame = markup.bounds
        fitPassesForCurrentSize = 0
        fitA4InViewport(animated: false)
    }

    /// The page this slot shows moved to `index` — pages were added or removed before it.
    /// Same page, same markup; only where it sits in the notebook changed.
    func updatePageIndex(_ index: Int) {
        pageIndex = index
    }

    // MARK: - A4 viewport

    /// Always asks PaperKit to show the whole page, nothing more — this canvas's
    /// view is sized to exactly one page by its tile, so "the whole page" and "the
    /// whole view" are the same rectangle. This is the hug: no internal scrolling,
    /// no internal zoom, one page filling the frame it was given.
    ///
    /// Re-running this after every layout pass is also what keeps zoom crisp. When
    /// the outer scroll view commits a new scale, the tile resizes, this fires, and
    /// PaperKit re-renders the ink at the new size rather than letting it be
    /// transform-magnified into blur.
    ///
    /// An earlier version computed its own scale/origin with an extra margin —
    /// logic carried forward from Delve's canvas, which fit an A4 page into a
    /// screen of a *different* aspect ratio and needed to center it by hand. That
    /// math stopped making sense once the surrounding frame already matched A4's
    /// aspect ratio: passing a non-zero origin while still asking for the full page
    /// size requested a region that didn't line up with what was on screen, and
    /// `contentVisibleFrame` read back slightly off a full page on every layout.
    /// Returns whether it had to change anything.
    ///
    /// The comparison is not an optimisation: this runs on every layout pass, and
    /// `setContentVisibleFrame` both schedules layout and calls the delegate — which
    /// asks for a fit in turn. Applying it only when the frame has actually drifted
    /// is what keeps that from being a cycle.
    @discardableResult
    private func fitA4InViewport(animated: Bool) -> Bool {
        guard let vc = paperVC, !isApplyingVisibleFrame else { return false }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return false }

        let target = visiblePageRect.applying(CGAffineTransform(scaleX: inkScale, y: inkScale))
        let current = vc.contentVisibleFrame
        let tolerance: CGFloat = 0.5
        guard abs(current.minX - target.minX) > tolerance
            || abs(current.minY - target.minY) > tolerance
            || abs(current.width - target.width) > tolerance
            || abs(current.height - target.height) > tolerance
        else { return false }

        isApplyingVisibleFrame = true
        vc.setContentVisibleFrame(target, animated: animated)
        isApplyingVisibleFrame = false
        return true
    }

    // MARK: - Tool picker

    /// Only ever attached to ONE slot at a time (whichever page is "active" — see
    /// `NotebookScrollViewController`). PaperKit expects a single active
    /// `PaperMarkupViewController` per tool picker; attaching more than one
    /// simultaneously risks tool actions (inserting a shape, etc.) targeting the
    /// wrong page.
    ///
    /// The picker's current tool is copied over on attach: observing only delivers
    /// *changes*, and a pooled canvas otherwise keeps whatever tool it last had — the
    /// picker showing red while the page drew black, until something was re-picked.
    func attachToolPicker(_ toolPicker: PKToolPicker) {
        guard Self.isEditingAvailable else { return }
        paperVC.drawingTool = toolPicker.selectedTool
        toolPicker.addObserver(paperVC)
        paperVC.pencilKitResponderState.activeToolPicker = toolPicker
        paperVC.pencilKitResponderState.toolPickerVisibility = .visible
        paperVC.becomeFirstResponder()
    }

    /// Whether this page's canvas is the first responder — what the tool picker's
    /// visibility follows. Something else on screen (the material pane's PDF view, a
    /// menu) can take it without this slot being detached.
    var canvasIsFirstResponder: Bool { paperVC.isFirstResponder }

    func detachToolPicker(_ toolPicker: PKToolPicker) {
        paperVC.pencilKitResponderState.toolPickerVisibility = .hidden
        paperVC.pencilKitResponderState.activeToolPicker = nil
        toolPicker.removeObserver(paperVC)
    }

    // MARK: - Selection

    /// What the user has selected on this page, or `nil` if nothing is selected.
    ///
    /// Prefers the live value and falls back to the cached one — see
    /// `lastNonEmptySelection` for why the live value alone is not enough.
    var currentSelection: PaperMarkup? {
        let live = paperVC.selectedMarkup
        if live.hasContent { return live }
        return lastNonEmptySelection
    }

    // MARK: - Clear / Undo

    func clear() {
        let oldMarkup = paperVC.markup
        paperVC.undoManager?.registerUndo(withTarget: self) { target in
            target.show(oldMarkup ?? .blankPage())
            target.inkDidChange()
        }
        paperVC.undoManager?.setActionName("Clear")

        show(.blankPage())
        inkDidChange()
    }

    private func inkDidChange() {
        hasUnsavedInk = true
        needsThumbnail = true
        onInkChanged?()
    }

    func undo() {
        paperVC.undoManager?.undo()
    }

    // MARK: - Thumbnail

    /// Renders the page's current ink as a thumbnail: transparent wherever there is
    /// no ink, since the tile draws the paper and grid. Drawn from the markup rather
    /// than snapshotted from the view — the view may show only part of the page (see
    /// `visiblePageRect`), and a markup render has a fixed pixel size whatever the
    /// zoom, where a snapshot of a deeply zoomed page ran to a gigabyte.
    ///
    /// Only the markup is read here, on the main thread; rendering and encoding run in
    /// the background (`PageRenderer.renderThumbnail`).
    func renderThumbnail() async -> (image: UIImage, png: Data)? {
        guard let markup = currentMarkup else { return nil }
        return await PageRenderer.renderThumbnail(markup)
    }
}

// MARK: - PaperMarkupViewController.Delegate

@MainActor
extension PageCanvasController: @preconcurrency PaperMarkupViewController.Delegate {

    func paperMarkupViewControllerDidChangeMarkup(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        strokeBeganAt = nil
        inkDidChange()
    }

    func paperMarkupViewControllerDidBeginDrawing(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        strokeBeganAt = Date()
    }

    func paperMarkupViewControllerDidChangeSelection(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        // A selection brings its own handles and drag recognisers; keep them Pencil-only.
        restrictInternalGestures()
        let selection = paperMarkupViewController.selectedMarkup
        guard selection.hasContent else { return }
        lastNonEmptySelection = selection
    }

    /// Puts the page back if PaperKit has moved or scaled it inside its tile.
    ///
    /// This canvas is supposed to have no zoom of its own — the visible frame is
    /// always exactly the page, and zoom lives in the outer scroll view. But
    /// `zoomRange` has to stay wide for the page to *render* at the tile's size (see
    /// `viewDidLoad`), which leaves PaperKit's own pinch recognisers armed;
    /// `restrictInternalGestures` switches off the ones it can find, and PaperKit
    /// installs them lazily, so a fast gesture can still get through to one. When it
    /// does, the page's ink and grid end up drawn at a scale the tile doesn't share
    /// — "the grid squares suddenly got much bigger" — and nothing corrected it until
    /// the next layout pass, which a settled canvas never gets.
    ///
    /// `fitA4InViewport` is a no-op unless the frame really drifted, and it guards
    /// its own re-entry, so this cannot become a cycle with the call it makes.
    func paperMarkupViewControllerDidChangeContentVisibleFrame(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        if fitA4InViewport(animated: false) {
            // Whatever recogniser did that is one this canvas has not disabled yet.
            restrictInternalGestures()
        }
    }
}


// MARK: - Selection emptiness

extension PaperMarkup {
    /// PaperKit exposes no "is anything selected" flag, and `selectedMarkup` is a
    /// perfectly valid — just empty — `PaperMarkup` when nothing is. An empty markup
    /// draws nothing, so its content bounding box is empty; `CGRect.isEmpty` is true
    /// for both `.null` and a zero-size rect, which covers however PaperKit spells it.
    var hasContent: Bool { !contentsRenderFrame.isEmpty }
}

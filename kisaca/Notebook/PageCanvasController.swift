//
//  PageCanvasController.swift
//  kisaca
//
//  One notebook page: a `PaperMarkupViewController` filling this controller's view,
//  set up the way Apple's PaperKit template and Notes use it — PaperKit owns the
//  page's scrolling and zooming, and the paper (white sheet + grid) is its
//  `contentView`. `NotebookPagerViewController` shows one of these at a time and
//  curls between them; it keeps a couple for reuse, so a page turn repoints an
//  existing canvas (`configure(...)`) instead of building PaperKit anew.
//
//  The page always fills the width it is given: zoom never goes below fit-to-width,
//  so there is no gap at either side. An A4 page at full width is taller than an
//  iPad screen in either orientation, so the rest of it is reached by scrolling
//  down inside the page.
//
//  Why this shape (2026-11-01): the previous design stacked several page-sized
//  PaperKit views inside our own zooming scroll view, with PaperKit's scrolling and
//  zooming switched off and its view oversized to hide its margin. PaperKit sizes
//  the Metal layer it draws the stroke in progress into to its view, so that design
//  paid for several screens of pixels per stroke frame. Here the view is the screen.
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

    /// The touches that may edit a page: Apple Pencil only, as on a device. The
    /// simulator has no Pencil, so for smoke-testing ink there a finger can be let in
    /// with a launch argument — `xcrun simctl launch <device> com.igalhan.kisaca
    /// -KisacaFingerInk YES`. Off by default, so fingers turn pages, scroll and open
    /// turn the tool wheel in the simulator exactly as they do on an iPad.
    private static let editingTouchTypes: [NSNumber] =
//        fingerInks
//        ?
    [UITouch.TouchType.pencil, .direct].map { NSNumber(value: $0.rawValue) }
//        :
//    [NSNumber(value: UITouch.TouchType.pencil.rawValue)]

    /// The simulator's opt-in finger ink (see `editingTouchTypes`). It also shows the
    /// system tool picker (see `activate`): PaperKit lets a finger draw only while one
    /// is on screen.
    private static let fingerInks: Bool = {
        #if targetEnvironment(simulator)
            UserDefaults.standard.bool(forKey: "KisacaFingerInk")
        #else
            false
        #endif
    }()

    /// Fingers scroll and zoom the page.
    private static let navigationTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

    /// How far past fit-to-width the page zooms in.
    private static let maximumZoomFactor: CGFloat = 4

    /// The page's index in the notebook, and its ID — `nil` for a page that doesn't
    /// exist yet: the blank one shown while turning past the last page, which only
    /// becomes a real page once the turn completes (`adopt(pageID:index:)`).
    private(set) var pageIndex: Int?
    private(set) var pageID: UUID?
    var isProvisional: Bool { pageID == nil }

    private var paperVC: PaperMarkupViewController!

    /// The paper: white, with the grid on it, in markup coordinates. PaperKit draws the
    /// ink over it and zooms both together.
    private let paper = UIView()
    private let grid = UIGridBackgroundView(frame: .zero)

    /// The page's markup space — `PageGeometry.newMarkupBounds`, or 595×842 for pages
    /// from before `PageGeometry.inkScale`.
    private var markupBounds = PageGeometry.newMarkupBounds

    /// The markup of whatever page this canvas currently shows.
    ///
    /// Read on demand — when saving, rendering a thumbnail or exporting — not copied
    /// out after every stroke. The getter hands back a whole-page value built from
    /// PaperKit's live model, and the delegate callback that used to read it fires on
    /// the main thread at the end of every stroke, which is right when the next one is
    /// about to start.
    var currentMarkup: PaperMarkup? { paperVC.markup }

    /// Whether the ink changed since it was last handed to the repository. Lets the
    /// autosave timer skip a page nobody touched.
    var hasUnsavedInk = false

    /// Whether the ink changed since the last thumbnail was rendered.
    var needsThumbnail = false

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
    /// with it. Reset in `configure(...)` so a reused canvas never reports the previous
    /// page's selection.
    private var lastNonEmptySelection: PaperMarkup?

    /// Pinned to fit-to-width — the "Fit Notebook Page to Width" setting.
    var zoomIsLocked = false {
        didSet { if zoomIsLocked != oldValue { applyZoomRange() } }
    }

    /// The page-turn recognisers. PaperKit's own scroll pans wait for them to fail,
    /// so a sideways swipe turns the page and anything else scrolls it — the turn
    /// recognisers refuse to begin while the page is zoomed in, or for a vertical swipe.
    var turnRecognizers: [UIGestureRecognizer] = [] {
        didSet { restrictInternalGestures() }
    }
    private var pansYieldingToTurns: Set<ObjectIdentifier> = []

    /// PaperKit's own scroll views, found by `restrictInternalGestures`.
    private var paperScrollViews: [WeakScrollView] = []

    /// Whether the page is zoomed in past fit-to-width.
    var isZoomedIn: Bool {
        let visible = paperVC.contentVisibleFrame
        return visible.width > 0 && visible.width < markupBounds.width * 0.98
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0xFFFCFA)

        paper.backgroundColor = UIColor(hex: 0xFFFCFA)
        paper.isUserInteractionEnabled = false
        paper.addSubview(grid)

        let vc = PaperMarkupViewController(markup: .blankPage(), supportedFeatureSet: .latest)
        // Finger doesn't draw — it scrolls, zooms and turns pages. Drawing is Apple
        // Pencil's job. `.selection` alone still lets a finger select and move ink;
        // `restrictInternalGestures` takes that away too, so editing of any kind is
        // Pencil only.
        vc.directTouchMode = .selection
        vc.directTouchAutomaticallyDraws = false
        vc.isEditable = Self.isEditingAvailable
        vc.overrideUserInterfaceStyle = .light  // Page is always white paper — fixes the loupe background.
        vc.contentView = paper
        if #available(iOS 26.1, *) { vc.showsHorizontalScrollIndicator = false }
        // Pin the default ink rather than trust PaperKit's ambient default, which
        // follows the tool picker's trait — a dark picker defaulted to white ink,
        // invisible on this always-white page.
        vc.drawingTool = PKInkingTool(.pen, color: .black)
        vc.view.backgroundColor = .white

        paperVC = vc
        vc.delegate = self
        addChild(vc)
        view.addSubview(vc.view)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.didMove(toParent: self)
        layOutPaper()
        restrictInternalGestures()
    }

    private var lastFittedSize: CGSize = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0,
            view.bounds.size != lastFittedSize
        else { return }
        lastFittedSize = view.bounds.size
        applyZoomRange()
        fitWidth(top: paperVC.contentVisibleFrame.minY)
        restrictInternalGestures()
    }

    // MARK: - Fit to width

    /// Screen points per markup point at which the page exactly fills the width.
    private var fitZoom: CGFloat {
        markupBounds.width > 0 ? view.bounds.width / markupBounds.width : 1
    }

    /// Zoom never goes below fit-to-width — that is what keeps the page edge to edge.
    private func applyZoomRange() {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        let fit = fitZoom
        paperVC.zoomRange = fit...(fit * (zoomIsLocked ? 1 : Self.maximumZoomFactor))
    }

    /// Shows the page at full width, scrolled so markup-space `top` is at the top of
    /// the view (clamped to the page).
    private func fitWidth(top: CGFloat) {
        guard isViewLoaded, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let width = markupBounds.width
        let height = width * view.bounds.height / view.bounds.width
        let maxTop = max(markupBounds.height - height, 0)
        let y = min(max(top.isFinite ? top : 0, 0), maxTop)
        paperVC.setContentVisibleFrame(
            CGRect(x: markupBounds.minX, y: markupBounds.minY + y, width: width, height: height),
            animated: false)
    }

    private func layOutPaper() {
        paper.frame = markupBounds
        grid.frame = paper.bounds
        // The grid works in page points; the paper is in markup points.
        grid.pageScale = markupBounds.width / PageGeometry.a4Size.width
    }

    // MARK: - Gestures

    /// PaperKit's internal recognisers, sorted by job. Scrolling and zooming are the
    /// finger's: PaperKit's scroll views keep their pan and pinch, limited to direct
    /// touches, and their pans wait for a page turn to fail first. Everything else —
    /// drawing, lasso, tapping or dragging a selection, editing a text box — is the
    /// Pencil's. `directTouchMode` has no "finger does nothing" setting (only
    /// `.drawing` or `.selection`), so this is what makes editing Pencil-only.
    ///
    /// These are ordinary public `UIGestureRecognizer` and `UIScrollView` objects
    /// reached through the view hierarchy; no private API is touched. PaperKit installs
    /// some lazily, so this runs again on configure, layout and selection changes.
    private func restrictInternalGestures() {
        guard let paperVC else { return }
        let editing = Self.editingTouchTypes
        let navigation = Self.navigationTouchTypes
        var navigationRecognizers: Set<ObjectIdentifier> = []
        var scrollPans: [UIGestureRecognizer] = []
        var scrollViews: [UIScrollView] = []

        func collect(in root: UIView) {
            if let scrollView = root as? UIScrollView {
                scrollViews.append(scrollView)
                navigationRecognizers.insert(ObjectIdentifier(scrollView.panGestureRecognizer))
                scrollPans.append(scrollView.panGestureRecognizer)
                if let pinch = scrollView.pinchGestureRecognizer {
                    navigationRecognizers.insert(ObjectIdentifier(pinch))
                }
            }
            root.subviews.forEach(collect)
        }
        func restrict(in root: UIView) {
            for recognizer in root.gestureRecognizers ?? [] {
                let isNavigation =
                    navigationRecognizers.contains(ObjectIdentifier(recognizer))
                    || recognizer is UIPinchGestureRecognizer
                let types = isNavigation ? navigation : editing
                if recognizer.allowedTouchTypes != types { recognizer.allowedTouchTypes = types }
            }
            root.subviews.forEach(restrict)
        }
        collect(in: paperVC.view)
        restrict(in: paperVC.view)
        paperScrollViews = scrollViews.map(WeakScrollView.init)
        updateBounce()

        for pan in scrollPans where !pansYieldingToTurns.contains(ObjectIdentifier(pan)) {
            for turn in turnRecognizers { pan.require(toFail: turn) }
            if !turnRecognizers.isEmpty { pansYieldingToTurns.insert(ObjectIdentifier(pan)) }
        }
    }

    /// No rubber-banding at fit-to-width: the page doesn't stretch past its edges
    /// when scrolled to the top or bottom, and a pinch can't squeeze it below full
    /// width and spring back. Zoomed in, scrolling bounces as usual — it is what tells
    /// you you've reached the edge of the page.
    private func updateBounce() {
        let bounces = isZoomedIn
        for scrollView in paperScrollViews.compactMap(\.view) {
            if scrollView.bounces != bounces { scrollView.bounces = bounces }
            if scrollView.bouncesZoom { scrollView.bouncesZoom = false }
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
        }
    }

    // MARK: - Configure (reuse entry point)

    /// Repoints this canvas at a page, shown from its top at full width.
    func configure(pageIndex: Int, pageID: UUID?, markup: PaperMarkup, gridSpacing: CGFloat) {
        loadViewIfNeeded()
        self.pageIndex = pageIndex
        self.pageID = pageID
        grid.spacing = gridSpacing
        lastNonEmptySelection = nil
        needsThumbnail = false
        hasUnsavedInk = false
        strokeBeganAt = nil
        show(markup)
        fitWidth(top: 0)
        restrictInternalGestures()
    }

    /// The blank page shown while turning past the last page became a real one.
    func adopt(pageID: UUID, index: Int) {
        self.pageID = pageID
        pageIndex = index
    }

    /// The page this canvas shows moved to `index` — pages were added or removed before it.
    func updatePageIndex(_ index: Int) {
        pageIndex = index
    }

    /// Hands `markup` to PaperKit along with its coordinate space: old and new pages
    /// differ in size (see `PageGeometry.inkScale`), and a reused canvas shows both.
    private func show(_ markup: PaperMarkup) {
        let top = paperVC.contentVisibleFrame.minY
        paperVC.markup = markup
        if markup.bounds != markupBounds {
            markupBounds = markup.bounds
            layOutPaper()
            applyZoomRange()
            fitWidth(top: top)
        }
    }

    // MARK: - Tools

    /// Hands the notebook's tool (`NotebookToolbox`) to this page and makes its canvas
    /// first responder — what undo and PaperKit's editing follow.
    ///
    /// The system tool picker is attached but `.hidden` (2026-11-09): our sidebar
    /// replaces its bar, but PaperKit only edits while a picker is *active* —
    /// with none, the page is view-only (checked in the simulator: no picker, no ink).
    /// `.hidden` is PencilKit's "active but offscreen": editable, Pencil double-tap and
    /// squeeze still work, nothing on screen. The page is deliberately *not* the
    /// picker's observer, so the tool comes from `drawingTool` — ours; the pager syncs
    /// the picker's own changes (a Pencil double-tap to the eraser) into the toolbox.
    ///
    /// The simulator's finger ink (`fingerInks`) shows the picker: a finger only draws
    /// while one is visible.
    func activate(tool: any PKTool, rulerActive: Bool, picker: PKToolPicker) {
        guard Self.isEditingAvailable else { return }
        let state = paperVC.pencilKitResponderState
        if state.activeToolPicker !== picker { state.activeToolPicker = picker }
        let visibility: PKToolPickerVisibility = Self.fingerInks ? .visible : .hidden
        if state.toolPickerVisibility != visibility { state.toolPickerVisibility = visibility }
        if !paperVC.isFirstResponder { paperVC.becomeFirstResponder() }
        // After the picker: attaching it hands PaperKit the picker's own tool.
        paperVC.drawingTool = tool
        if paperVC.isRulerActive != rulerActive { paperVC.isRulerActive = rulerActive }
        // Becoming first responder installs more of PaperKit's recognisers (its
        // tap-for-edit-menu among them); keep them Pencil-only too.
        restrictInternalGestures()
    }

    /// The page left the screen: no longer the picker's.
    func deactivate() {
        paperVC.pencilKitResponderState.toolPickerVisibility = .inactive
        paperVC.pencilKitResponderState.activeToolPicker = nil
    }

    /// Whether this page's canvas is the first responder. Something else on screen
    /// (the material pane's PDF view, a menu) can take it.
    var canvasIsFirstResponder: Bool { paperVC.isFirstResponder }

    /// Called whenever undo / redo may have changed — the sidebar enables its buttons.
    var onUndoStateChange: () -> Void = {}

    /// The Pencil started a stroke (writing, erasing, lassoing) with the tool in hand.
    var onBeginDrawing: () -> Void = {}

    var canUndo: Bool { paperVC.undoManager?.canUndo ?? false }
    var canRedo: Bool { paperVC.undoManager?.canRedo ?? false }

    /// Colour for shapes and lines added from the insert menu — the pen's.
    var insertColor: UIColor = .black

    /// The page's coordinate space, for sizing what the insert menu adds.
    var markupScale: CGFloat { markupBounds.width / PageGeometry.a4Size.width }

    // MARK: - Selection

    /// What the user has selected on this page, or `nil` if nothing is selected.
    /// Prefers the live value and falls back to the cached one — see
    /// `lastNonEmptySelection`.
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
        onUndoStateChange()
    }

    func undo() {
        paperVC.undoManager?.undo()
        onUndoStateChange()
    }

    func redo() {
        paperVC.undoManager?.redo()
        onUndoStateChange()
    }

    // MARK: - Insert (PaperKit's insert menu)

    /// Adds something from `MarkupEditViewController` in the middle of what's on
    /// screen, nudged by PaperKit off existing content; undoable as one step.
    /// `PaperMarkupViewController` doesn't (publicly) take the menu's delegate calls
    /// itself, so the page edits its markup and hands it back.
    private func insert(_ change: (inout PaperMarkup, CGRect) -> Void, size: CGSize) {
        guard var markup = paperVC.markup else { return }
        let old = markup
        let visible = paperVC.contentVisibleFrame
        let proposed = CGRect(
            x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
            width: size.width, height: size.height)
        change(&markup, paperVC.suggestedFrameForInserting(contentInFrame: proposed))
        paperVC.undoManager?.registerUndo(withTarget: self) { target in
            target.show(old)
            target.inkDidChange()
        }
        paperVC.undoManager?.setActionName("Insert")
        show(markup)
        inkDidChange()
    }

    private func shapeStyle(_ type: ShapeConfiguration.Shape) -> ShapeConfiguration {
        ShapeConfiguration(
            type: type, fillColor: nil, strokeColor: insertColor.cgColor,
            lineWidth: 2 * markupScale)
    }

    // MARK: - Thumbnail

    /// Renders the page's current ink as a thumbnail (ink only, on transparency).
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
        onBeginDrawing()
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

    func paperMarkupViewControllerDidChangeContentVisibleFrame(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        updateBounce()
    }
}

// MARK: - MarkupEditViewController.Delegate

@MainActor
extension PageCanvasController: @preconcurrency MarkupEditViewController.Delegate {
    func markupEditViewController(
        _ markupEditViewController: MarkupEditViewController,
        insertNewShape type: ShapeConfiguration.Shape
    ) {
        let side = 70 * markupScale
        let style = shapeStyle(type)
        insert({ $0.insertNewShape(configuration: style, frame: $1) }, size: CGSize(width: side, height: side))
    }

    func markupEditViewControllerInsertNewTextbox(
        _ markupEditViewController: MarkupEditViewController
    ) {
        let text = NSAttributedString(
            string: "Text",
            attributes: [
                .font: UIFont.systemFont(ofSize: 12 * markupScale),
                .foregroundColor: insertColor,
            ])
        insert(
            { $0.insertNewTextbox(attributedText: text, frame: $1) },
            size: CGSize(width: 120 * markupScale, height: 24 * markupScale))
    }

    func markupEditViewController(
        _ markupEditViewController: MarkupEditViewController,
        insertNewLineWithStartMarker lineStartMarker: Bool, endMarker lineEndMarker: Bool
    ) {
        let style = shapeStyle(.line)
        insert(
            {
                $0.insertNewLine(
                    configuration: style, from: CGPoint(x: $1.minX, y: $1.midY),
                    to: CGPoint(x: $1.maxX, y: $1.midY),
                    startMarker: lineStartMarker, endMarker: lineEndMarker)
            }, size: CGSize(width: 100 * markupScale, height: 10 * markupScale))
    }

    func markupEditViewController(
        _ markupEditViewController: MarkupEditViewController,
        insertNewContents toInsert: PaperMarkup
    ) {
        insert({ markup, _ in markup.append(contentsOf: toInsert) }, size: .zero)
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

/// A scroll view PaperKit owns — held weakly, so a view it replaces isn't kept alive.
private struct WeakScrollView {
    weak var view: UIScrollView?
    init(_ view: UIScrollView) { self.view = view }
}

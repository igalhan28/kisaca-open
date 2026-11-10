//
//  NotebookPagerViewController.swift
//  kisaca
//
//  The notebook, one page at a time, turned like a book: a `UIPageViewController`
//  in page-curl style, the way Apple Books turns pages. Each page is a
//  `PageCanvasController` — one PaperKit canvas filling the width this controller is
//  given, scrolling and zooming itself.
//
//  ## Gestures
//  - Pencil writes. It never scrolls, zooms or turns (`PageCanvasController`
//    restricts PaperKit's editing recognisers to it; the turn recognisers here
//    exclude it).
//  - Pages turn only from the turn zones — a strip along each side edge (`turnZone`):
//    a one-finger sideways swipe that starts in the right strip turns forward, in the
//    left strip back. Taps never turn (UIKit's own tap-to-turn is switched off): a
//    finger tap anywhere hides or shows the controls (`NotebookViewController`).
//    Anywhere else a finger drag scrolls the page and a pinch zooms it. While a page is zoomed in, nothing turns —
//    `TurnGestureGate` holds the turn recognisers back.
//  - Never with more than one finger down: a turn doesn't start then, and one in
//    progress is called off when a second finger lands (`TouchCounter`), so a pinch
//    or two-finger swipe can't turn the page by accident.
//  - The curl runs at twice UIKit's speed (`setTurnSpeed`).
//  - Turning forward from the last page adds a new blank page. Until the turn
//    completes it is only provisional, so a turn begun and abandoned adds nothing.
//
//  ## Memory
//  One live canvas is on screen; a turn adds the one being turned to. Canvases that
//  leave the screen go back to a small pool and are repointed at the next page asked
//  for, so turning pages doesn't build PaperKit anew each time. Each canvas is the
//  size of the screen, whatever the zoom — PaperKit scrolls inside it.
//

import PaperKit
import PencilKit
import UIKit

@MainActor
final class NotebookPagerViewController: UIViewController {

    /// Off-screen canvases kept for reuse.
    private static let poolLimit = 2

    // MARK: - Dependencies

    private let repository: PageRepository
    weak var coordinator: NotebookCoordinator?

    /// Page to open at instead of the first — a whole-section notebook opens at its
    /// latest session, not at week 1. Read once, when the view loads.
    var initialPageIndex: Int?

    // MARK: - Views

    private let pageViewController = UIPageViewController(
        transitionStyle: .pageCurl,
        navigationOrientation: .horizontal,
        options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])

    /// The tool the Pencil holds — set by `NotebookViewController`, shared with the
    /// sidebar and the tool wheel. Handed to the page on screen (`activateCurrentPage`).
    var toolbox: NotebookToolbox?

    /// Undo / redo may have changed on the page on screen.
    var onUndoStateChange: () -> Void = {}
    /// The Pencil began a stroke on the page on screen.
    var onBeginDrawing: () -> Void = {}

    /// The system tool picker, attached `.hidden` to the page on screen — no bar, but
    /// PaperKit only edits with an active picker (see `PageCanvasController.activate`).
    /// Its colours are made for the always-white page.
    private let toolPicker: PKToolPicker = {
        let picker = PKToolPicker()
        picker.colorUserInterfaceStyle = .light
        return picker
    }()
    /// The picker's last selection was the eraser — so its next change, back to ink,
    /// is the Pencil's double-tap switching back, not a new ink chosen.
    private var pickerWasOnEraser = false

    private lazy var turnGate = TurnGestureGate { [weak self] recognizer in
        self?.mayTurn(with: recognizer) ?? false
    }

    /// Counts fingers on the notebook, and gives the page focus back on touch-down.
    private let touchCounter = TouchCounter()

    // MARK: - State

    private var pool: [PageCanvasController] = []
    /// The canvas a turn in progress is bringing in.
    private var pendingPages: [PageCanvasController] = []
    private weak var activePage: PageCanvasController?

    private var currentPage: PageCanvasController? {
        pageViewController.viewControllers?.first as? PageCanvasController
    }

    private var currentIndex: Int { currentPage?.pageIndex ?? 0 }

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

        pageViewController.isDoubleSided = false
        pageViewController.dataSource = self
        pageViewController.delegate = self
        addChild(pageViewController)
        pageViewController.view.frame = view.bounds
        pageViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageViewController.view)
        pageViewController.didMove(toParent: self)

        let count = repository.pageCount
        let start = min(max(initialPageIndex ?? 0, 0), max(count - 1, 0))
        let first = canvas(forPageAt: start)
        pageViewController.setViewControllers([first], direction: .forward, animated: false)

        // Fingers turn pages; the Pencil only writes. A turn recogniser that saw the
        // Pencil would compete with drawing for every stroke near the page's edge.
        // After `setViewControllers`, not before: the page view controller creates its
        // curl recognisers only once it has a page, and an empty list here left the
        // turns ungated — the first-page crash `mayTurn` guards against.
        let finger = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for recognizer in pageViewController.gestureRecognizers {
            recognizer.allowedTouchTypes = finger
            (recognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches = 1
            recognizer.addTarget(self, action: #selector(turnGestureChanged(_:)))
            turnGate.install(on: recognizer)
        }
        first.turnRecognizers = pageViewController.gestureRecognizers

        // Any finger on the notebook gives the page focus back if something else took
        // first responder — see `reclaimFocus()` — and a second finger calls off a
        // turn. The counter never recognises, so turning, scrolling, zooming and
        // drawing all still get the touch.
        touchCounter.onChange = { [weak self] count, added in
            guard let self else { return }
            if added, count == 1 { reclaimFocus() }
            if count > 1 { cancelTurnInProgress() }
        }
        view.addGestureRecognizer(touchCounter)
        toolPicker.addObserver(self)

        updatePageCounter()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateCurrentPage()
        setBackGesturesEnabled(false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushActivePage()
        setBackGesturesEnabled(true)
        setTurnSpeed(1)
    }

    /// The navigation controller's swipe-back gestures — from the left edge, and on
    /// iOS 26 from anywhere in the content — are off while the notebook is on screen:
    /// a swipe to the right is turning back a page here. Leaving is the back button.
    /// Restored on the way out, so every other screen keeps them.
    private func setBackGesturesEnabled(_ enabled: Bool) {
        guard let navigationController else { return }
        navigationController.interactivePopGestureRecognizer?.isEnabled = enabled
        navigationController.interactiveContentPopGestureRecognizer?.isEnabled = enabled
    }

    // MARK: - Canvases

    /// A canvas showing the page at `index` — or, one past the last page, the blank
    /// page a forward turn there would add.
    private func canvas(forPageAt index: Int) -> PageCanvasController {
        let canvas = pool.popLast() ?? makeCanvas()
        let ids = repository.pageIDs
        if index < ids.count {
            canvas.configure(
                pageIndex: index, pageID: ids[index],
                markup: repository.loadMarkup(forPageAt: index),
                gridSpacing: repository.gridSpacing(forPageAt: index))
        } else {
            canvas.configure(
                pageIndex: index, pageID: nil, markup: .blankPage(),
                gridSpacing: repository.gridSpacing(forPageAt: max(ids.count - 1, 0)))
        }
        return canvas
    }

    private func makeCanvas() -> PageCanvasController {
        let canvas = PageCanvasController()
        canvas.loadViewIfNeeded()
        canvas.zoomIsLocked = forcesFitWidth
        canvas.turnRecognizers = pageViewController.gestureRecognizers
        return canvas
    }

    /// Takes back a canvas that is no longer on screen.
    private func recycle(_ canvas: PageCanvasController) {
        guard canvas !== currentPage else { return }
        if canvas === activePage {
            canvas.onUndoStateChange = {}
            canvas.onBeginDrawing = {}
            canvas.deactivate()
            activePage = nil
        }
        guard pool.count < Self.poolLimit, !pool.contains(where: { $0 === canvas }) else { return }
        pool.append(canvas)
    }

    /// The "Fit Notebook Page to Width" preference: no zooming in.
    private var forcesFitWidth: Bool {
        UserDefaults.standard.bool(forKey: AppPreferences.Key.notebookFitsWidth)
    }

    // MARK: - Turning

    enum TurnZone { case back, forward }

    /// The strip along a side edge where a finger turns the page: the right one
    /// forward, the left one back. Everywhere else is the page's
    /// own — fingers scroll, zoom, and tap to hide the controls there.
    func turnZone(at point: CGPoint) -> TurnZone? {
        let width = max(64, view.bounds.width * 0.1)
        if point.x >= view.bounds.maxX - width { return .forward }
        if point.x <= width { return .back }
        return nil
    }

    /// Whether a turn recogniser may begin. Only from a turn zone, towards the page
    /// that zone turns to, with one finger down; not while the page is zoomed in — a
    /// sideways swipe pans it then — and a pan only when it is mostly sideways, so a
    /// vertical drag in the strip still scrolls the page.
    ///
    /// Nor towards a page that doesn't exist. A page-curl `UIPageViewController` starts
    /// the curl before asking its data source, and throws ("The number of view
    /// controllers provided (0) doesn't match the number required (1)") when the
    /// answer is `nil` — a swipe right on the first page crashed the app.
    private func mayTurn(with recognizer: UIGestureRecognizer) -> Bool {
        guard let page = currentPage, !page.isZoomedIn, touchCounter.count <= 1 else {
            return false
        }
        // Only the curl's pan; its tap-to-turn never begins.
        guard let pan = recognizer as? UIPanGestureRecognizer, pan.numberOfTouches <= 1 else {
            return false
        }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        let translation = pan.translation(in: view)
        let location = pan.location(in: view)
        let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        let forward = velocity.x < 0
        guard turnZone(at: start) == (forward ? .forward : .back), hasPage(forward: forward)
        else { return false }
        setTurnSpeed(Self.turnSpeed)
        return true
    }

    /// How much faster than UIKit's own the curl runs.
    private static let turnSpeed: Float = 2

    /// Speeds the page view controller's animations up — the curl's, when the finger
    /// lets go and for taps and programmatic turns — by retiming its layer, the only
    /// handle `UIPageViewController` gives on the curl's duration. Set just before a
    /// turn and back to 1 after it, so PaperKit's own animations keep their pace.
    /// Re-anchors the layer's clock at the switch so nothing in flight jumps.
    private func setTurnSpeed(_ speed: Float) {
        let layer = pageViewController.view.layer
        guard layer.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = layer.convertTime(now, from: nil)
        layer.speed = speed
        layer.timeOffset = local
        layer.beginTime = now
    }

    /// A turn recogniser finished without the page view controller starting a turn —
    /// put the speed back, as no `didFinishAnimating` will.
    @objc private func turnGestureChanged(_ recognizer: UIGestureRecognizer) {
        switch recognizer.state {
        case .ended, .cancelled, .failed:
            DispatchQueue.main.async { [weak self] in
                guard let self, pendingPages.isEmpty else { return }
                setTurnSpeed(1)
            }
        default: break
        }
    }

    /// A second finger landed: a turn being dragged goes back.
    private func cancelTurnInProgress() {
        for recognizer in pageViewController.gestureRecognizers
        where recognizer.state == .began || recognizer.state == .changed {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }

    /// Whether there is a page to turn to — matching what the data source returns.
    private func hasPage(forward: Bool) -> Bool {
        guard let page = currentPage, let index = page.pageIndex else { return false }
        guard forward else { return index > 0 }
        return !page.isProvisional
            && (index + 1 < repository.pageCount || PageCanvasController.isEditingAvailable)
    }

    /// Shows `index` with a turn — the toolbar's add page, and anything else that
    /// jumps. The page leaving is flushed first.
    private func turn(to index: Int, direction: UIPageViewController.NavigationDirection) {
        guard let leaving = currentPage else { return }
        flush(leaving)
        let arriving = canvas(forPageAt: index)
        setTurnSpeed(Self.turnSpeed)
        pageViewController.setViewControllers([arriving], direction: direction, animated: true) {
            [weak self] _ in
            guard let self else { return }
            setTurnSpeed(1)
            recycle(leaving)
            didShowPage()
        }
        updatePageCounter()
    }

    /// After any change of page: the tool moves to it, the bar follows it.
    private func didShowPage() {
        activateCurrentPage()
        updatePageCounter()
    }

    // MARK: - Tools

    /// Hands the toolbox's tool to the page on screen and makes it the page undo and
    /// editing go to. Runs on every page change and every tool change.
    func activateCurrentPage() {
        guard let page = currentPage else { return }
        if page !== activePage {
            activePage?.onUndoStateChange = {}
            activePage?.onBeginDrawing = {}
            activePage?.deactivate()
            activePage = page
            page.onUndoStateChange = { [weak self] in self?.onUndoStateChange() }
            page.onBeginDrawing = { [weak self] in self?.onBeginDrawing() }
        }
        if let toolbox {
            page.activate(tool: toolbox.tool, rulerActive: toolbox.isRulerActive, picker: toolPicker)
            page.insertColor = toolbox.currentColor
        }
        onUndoStateChange()
    }

    /// Gives the page focus back when something else took first responder from it —
    /// the material pane's PDF view, for one.
    func reclaimFocus() {
        guard let page = currentPage else { return }
        guard page !== activePage || !page.canvasIsFirstResponder else { return }
        activateCurrentPage()
    }

    /// The page on screen — the insert menu's delegate.
    var currentCanvas: PageCanvasController? { currentPage }

    var canUndo: Bool { currentPage?.canUndo ?? false }
    var canRedo: Bool { currentPage?.canRedo ?? false }

    private func updatePageCounter() {
        let count = repository.pageCount
        let current = min(max(currentIndex, 0), max(count - 1, 0))
        coordinator?.currentPageIndex = current
        coordinator?.totalPages = count
        coordinator?.canDeleteCurrentPage = repository.canRemovePage(at: current)
        let title = repository.sessionTitle(forPageAt: current)
        if coordinator?.currentSessionTitle != title { coordinator?.currentSessionTitle = title }
        let sessionID = repository.session(forPageAt: current)?.id
        if coordinator?.currentSessionID != sessionID { coordinator?.currentSessionID = sessionID }
    }

    // MARK: - Save / thumbnail

    /// Hands the canvas's ink to the repository if it changed since the last flush,
    /// and stores a fresh thumbnail if the ink changed since the last one. A page
    /// nobody wrote on costs nothing. A provisional page has nothing to save.
    private func flush(_ canvas: PageCanvasController) {
        guard let pageID = canvas.pageID else { return }
        if canvas.hasUnsavedInk, let markup = canvas.currentMarkup {
            canvas.hasUnsavedInk = false
            repository.saveMarkup(markup, forPageID: pageID)
        }
        guard canvas.needsThumbnail else { return }
        canvas.needsThumbnail = false
        // Rendered and encoded off the main thread — see `PageRenderer`.
        Task { [weak self] in
            guard let thumbnail = await canvas.renderThumbnail(), let self else { return }
            repository.saveThumbnail(png: thumbnail.png, for: pageID)
        }
    }

    /// Called on scene backgrounding, before PDF export and on leaving the screen.
    func flushActivePage() {
        guard let page = currentPage else { return }
        flush(page)
    }

    /// The autosave timer's flush: same as `flushActivePage`, except that it never
    /// runs in the middle of a stroke — the next tick picks the page up instead.
    func autosaveActivePage() {
        guard let page = currentPage, !page.isDrawing else { return }
        flush(page)
    }

    var activeMarkup: PaperMarkup? { currentPage?.currentMarkup }

    /// The selection on the page on screen, or `nil` when nothing is selected there.
    var activeSelection: PaperMarkup? { currentPage?.currentSelection }

    // MARK: - Public interface (toolbar)

    /// Inserts a blank page after the current one and turns to it. Deliberate action
    /// only.
    func addPage() {
        guard let new = repository.insertPage(after: currentIndex) else { return }
        turn(to: new, direction: .forward)
    }

    /// Deletes the current page and its ink; the page after it (or, for the last, the
    /// one before) takes its place. The last page of a session stays — see
    /// `PageRepository.canRemovePage`.
    func deleteCurrentPage() {
        let index = currentIndex
        guard repository.canRemovePage(at: index), let leaving = currentPage else { return }
        // No flush: its ink is about to be deleted.
        leaving.hasUnsavedInk = false
        leaving.needsThumbnail = false
        repository.removePage(at: index)
        let next = min(index, repository.pageCount - 1)
        pageViewController.setViewControllers(
            [canvas(forPageAt: next)], direction: .forward, animated: false)
        recycle(leaving)
        didShowPage()
    }

    func clearActivePage() {
        currentPage?.clear()
    }

    func undoActivePage() {
        currentPage?.undo()
    }

    func redoActivePage() {
        currentPage?.redo()
    }
}

// MARK: - UIPageViewControllerDataSource

@MainActor
extension NotebookPagerViewController: UIPageViewControllerDataSource {

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? PageCanvasController,
            let index = page.pageIndex, index > 0
        else { return nil }
        return canvas(forPageAt: index - 1)
    }

    /// One past the last page is a provisional blank page — see the type doc.
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? PageCanvasController,
            let index = page.pageIndex, !page.isProvisional,
            index + 1 <= repository.pageCount,
            PageCanvasController.isEditingAvailable || index + 1 < repository.pageCount
        else { return nil }
        return canvas(forPageAt: index + 1)
    }
}

// MARK: - UIPageViewControllerDelegate

@MainActor
extension NotebookPagerViewController: UIPageViewControllerDelegate {

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        pendingPages = pendingViewControllers.compactMap { $0 as? PageCanvasController }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        let previous = previousViewControllers.compactMap { $0 as? PageCanvasController }
        if completed {
            for page in previous {
                flush(page)
                recycle(page)
            }
            if let page = currentPage, page.isProvisional, let index = page.pageIndex,
                let new = repository.insertPage(after: index - 1)
            {
                page.adopt(pageID: repository.pageIDs[new], index: new)
            }
            didShowPage()
        } else {
            pendingPages.forEach(recycle)
        }
        pendingPages = []
        setTurnSpeed(1)
    }
}

// MARK: - PKToolPickerObserver

@MainActor
extension NotebookPagerViewController: @preconcurrency PKToolPickerObserver {
    /// The hidden picker changed its own selection — what the Pencil's double-tap does
    /// ("switch to eraser" / back). Carried into the toolbox, which stays the one source
    /// of the tool: to the eraser, and back from it to the toolbox's own previous tool,
    /// not the picker's idea of it. Anything else is ignored — attaching the picker
    /// announces its default black pen, which must not overwrite the pen in hand.
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        guard let toolbox else { return }
        let onEraser = toolPicker.selectedToolItem is PKToolPickerEraserItem
        defer { pickerWasOnEraser = onEraser }
        if onEraser, !pickerWasOnEraser, toolbox.selected != .eraser {
            toolbox.select(.eraser)
        } else if !onEraser, pickerWasOnEraser, toolbox.selected == .eraser {
            toolbox.selectPrevious()
        }
    }
}

// MARK: - TouchCounter

/// Counts the fingers on the notebook. Never recognises — it only watches, so every
/// other recogniser and PaperKit's drawing still get the same touches — and fails
/// once the last finger lifts, which resets it for the next touch.
@MainActor
private final class TouchCounter: UIGestureRecognizer {
    private(set) var count = 0
    /// The new count, and whether a finger was added (rather than lifted).
    var onChange: (_ count: Int, _ added: Bool) -> Void = { _, _ in }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    convenience init() { self.init(target: nil, action: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        count += touches.count
        onChange(count, true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        count = max(count - touches.count, 0)
        onChange(count, false)
        if count == 0 { state = .failed }
    }

    override func reset() {
        super.reset()
        count = 0
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

// MARK: - TurnGestureGate

/// Sits in front of a page-turn recogniser's own delegate — `UIPageViewController`
/// installs one and relies on it — and adds a single condition to
/// `gestureRecognizerShouldBegin`. Every other delegate call is forwarded untouched.
@MainActor
private final class TurnGestureGate: NSObject, UIGestureRecognizerDelegate {
    private let mayBegin: (UIGestureRecognizer) -> Bool
    /// The page view controller's own delegates, by recogniser.
    private var originals: [ObjectIdentifier: UIGestureRecognizerDelegate] = [:]

    init(mayBegin: @escaping (UIGestureRecognizer) -> Bool) {
        self.mayBegin = mayBegin
    }

    func install(on recognizer: UIGestureRecognizer) {
        if let original = recognizer.delegate, original !== self {
            originals[ObjectIdentifier(recognizer)] = original
        }
        recognizer.delegate = self
    }

    private func original(of recognizer: UIGestureRecognizer) -> UIGestureRecognizerDelegate? {
        originals[ObjectIdentifier(recognizer)]
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard mayBegin(recognizer) else { return false }
        return original(of: recognizer)?.gestureRecognizerShouldBegin?(recognizer) ?? true
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        original(of: recognizer)?.gestureRecognizer?(recognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        original(of: recognizer)?.gestureRecognizer?(
            recognizer, shouldRecognizeSimultaneouslyWith: other) ?? false
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        original(of: recognizer)?.gestureRecognizer?(recognizer, shouldRequireFailureOf: other)
            ?? false
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        original(of: recognizer)?.gestureRecognizer?(recognizer, shouldBeRequiredToFailBy: other)
            ?? false
    }
}

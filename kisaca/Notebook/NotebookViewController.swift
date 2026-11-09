//
//  NotebookViewController.swift
//  kisaca
//
//  The note-taking screen: the notebook canvas (`NotebookPagerViewController`, a child)
//  for one `LectureSession` — or a whole section read as one notebook — and the bar
//  around it (page counter, add/delete page, undo, clear, export). Sits one level below
//  Section in the Lecture → Section → Session navigation. Replaced the SwiftUI
//  `NotebookScreen` + `NotebookHostView` in the UIKit migration
//  (docs/uikit-migration.md).
//
//  Course material can open beside the notebook (the split button): see
//  `MaterialPaneViewController` and "Material pane" below.
//
//  No navigation bar (2026-11-09): back and the split button float on the notebook's
//  own top-left corner, so they stay on the page side when material is open beside
//  it, and the tools are the rail down the notebook's leading edge (`ToolRailView`)
//  and the tool disk (`ToolDiskView`, two-finger sideways swipe) instead of the system
//  tool picker. A finger tap anywhere on the page hides all of it, the
//  status bar and the home indicator too, for a clean page — tap again to bring it
//  back. See "Chrome" below.
//
//  Owns the autosave timer's lifecycle (start on appear, flush + stop on disappear or
//  when the app leaves the active state) — see NotebookCoordinator.swift and
//  docs/document-format.md → "Autosave design".
//

import PaperKit
import UIKit
import UniformTypeIdentifiers

final class NotebookViewController: UIViewController {
    private let document: LectureDocument
    private let route: NotebookRoute
    private let coordinator = NotebookCoordinator()
    private let notebook: NotebookPagerViewController

    // MARK: - Chrome
    //
    // The corner buttons and the tool rail float over the notebook; `chromeHidden`
    // fades them (and the status bar and home indicator) out.

    private let toolbox = NotebookToolbox()
    private lazy var rail = ToolRailView { [weak self] action in self?.perform(action) }
    private var disk: ToolDiskView?
    private let cornerGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private var chromeHidden = false
    private var showsRail: Bool { PageCanvasController.isEditingAvailable }

    init(document: LectureDocument, route: NotebookRoute) {
        self.document = document
        self.route = route
        let repository = PageRepository(document: document, scope: route.scope)
        notebook = NotebookPagerViewController(repository: repository, coordinator: coordinator)
        notebook.initialPageIndex = route.initialSessionID.flatMap {
            repository.firstPageIndex(of: $0)
        }
        notebook.toolbox = toolbox
        coordinator.pager = notebook
        coordinator.pageRepository = repository
        coordinator.currentPageIndex = 0
        coordinator.totalPages = repository.pageCount
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Material pane state
    //
    // Side and width are device preferences (AppPreferences) — kept across launches, the
    // same for every lecture; whether it is open and what it shows are not.

    private var showingMaterialPane = false
    private var paneMaterialID: UUID?
    /// The pane beside the notebook (regular width).
    private var inlinePane: MaterialPaneViewController?
    /// The pane as a sheet over the notebook — no room for two panes side by side
    /// (iPhone, narrow Split View).
    private var sheetPane: MaterialPaneViewController?

    private let divider = PaneDivider()
    /// Where the divider will land while it is dragged. The panes resize only on release:
    /// resizing the notebook re-lays out and re-renders PaperKit, too heavy for every
    /// frame of a drag.
    private let dragIndicator = UIView()
    private var dragFraction: Double?

    private static let dividerWidth: CGFloat = 14

    // MARK: - Corner buttons

    private lazy var paneButton = cornerButton(
        "rectangle.split.2x1", label: "Open Material Beside Notes"
    ) { [weak self] in self?.toggleMaterialPane() }
    private lazy var backButton = cornerButton("chevron.backward", label: "Back") { [weak self] in
        self?.navigationController?.popViewController(animated: true)
    }

    private func cornerButton(_ symbol: String, label: String, action: @escaping () -> Void)
        -> UIButton
    {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 19, weight: .medium)
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 48),
        ])
        return button
    }
//    // Quick add: files land under this session's week and open beside the notes.
//    private lazy var addMaterialItem = UIBarButtonItem(
//        title: "Add Material", image: UIImage(systemName: "paperclip.badge.plus"),
//        primaryAction: UIAction { [weak self] _ in self?.showMaterialImporter() })
//    // Adds after the current page; deletes the current page. Moving between pages is
//    // scrolling — there are no previous/next buttons.
//    private lazy var addPageItem = UIBarButtonItem(
//        title: "Add Page", image: UIImage(systemName: "plus.rectangle.portrait"),
//        primaryAction: UIAction { [weak self] _ in self?.coordinator.addPage() })
//    private let pageCounterLabel = UILabel()
//    private lazy var pageCounterItem = UIBarButtonItem(customView: pageCounterLabel)
//    private lazy var deletePageItem = UIBarButtonItem(
//        title: "Delete Page", image: UIImage(systemName: "minus.rectangle.portrait"),
//        primaryAction: UIAction { [weak self] _ in self?.confirmDeletePage() })
//    // Stands in for "Search the Web for Selection". It can't live in PaperKit's own
//    // long-press menu next to "Copy as Text" — that menu takes no custom items — so it
//    // sits here and reads the selection off the canvas itself. See
//    // `NotebookCoordinator.showSelectedText()`.
//    private lazy var selectedTextItem = UIBarButtonItem(
//        title: "Selected Text", image: UIImage(systemName: "text.magnifyingglass"),
//        primaryAction: UIAction { [weak self] _ in self?.coordinator.showSelectedText() })
//    private lazy var exportItem = UIBarButtonItem(
//        title: "Export", image: UIImage(systemName: "square.and.arrow.up"),
//        primaryAction: UIAction { [weak self] _ in self?.showExportOptions() })
//    private lazy var undoItem = UIBarButtonItem(
//        title: "Undo", image: UIImage(systemName: "arrow.uturn.backward"),
//        primaryAction: UIAction { [weak self] _ in self?.coordinator.undo() })
//    private lazy var moreItem = UIBarButtonItem(
//        title: "More", image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil,
//        menu: UIMenu(children: [
//            UIAction(
//                title: "Clear Page", image: UIImage(systemName: "trash"), attributes: .destructive
//            ) { [weak self] _ in self?.coordinator.clear() }
//        ]))

    private let exportOverlay = ExportingOverlay()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        addChild(notebook)
        view.addSubview(notebook.view)
        notebook.didMove(toParent: self)

        divider.isHidden = true
        divider.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(dividerPanned(_:))))
        view.addSubview(divider)

        dragIndicator.backgroundColor = .tintColor
        dragIndicator.isUserInteractionEnabled = false
        dragIndicator.isHidden = true
        view.addSubview(dragIndicator)

        setUpChrome()

        exportOverlay.frame = view.bounds
        exportOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        exportOverlay.isHidden = true
        view.addSubview(exportOverlay)

//        // Compact: next to a long title ("Lectures · W12 · Thu") a "Page 5 of 23" label
//        // gets truncated, so the counter is just "5 / 23".
//        pageCounterLabel.font = UIFont.monospacedDigitSystemFont(
//            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
//        navigationItem.leftItemsSupplementBackButton = true
//        if PageCanvasController.isEditingAvailable {
//            navigationItem.leftBarButtonItems = [
//                paneItem, addMaterialItem, addPageItem, pageCounterItem, deletePageItem,
//            ]
//            navigationItem.rightBarButtonItems = [moreItem, undoItem, exportItem, selectedTextItem]
//        } else {
//            // iPhone reads notes, it doesn't write them: nothing that changes pages.
//            navigationItem.leftBarButtonItems = [paneItem, addMaterialItem, pageCounterItem]
//            navigationItem.rightBarButtonItems = [exportItem]
//        }

        coordinator.onPDFReady = { [weak self] url in self?.share(url) }
        coordinator.onSelectedText = { [weak self] message in
            self?.showAlert(title: "Selected Text", message: message)
        }

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) {
            (self: NotebookViewController, _) in
            self.placePane(animated: false)
        }
        // Leaving the active state (inactive or background).
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate),
            name: UIScene.willDeactivateNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        coordinator.startAutosaveTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override var prefersStatusBarHidden: Bool { chromeHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        coordinator.stopAutosaveTimer()
        coordinator.flushActivePage()
    }

    @objc private func sceneWillDeactivate() {
        coordinator.flushActivePage()
    }

    /// Everything the bar shows. Reads the coordinator and the document, so UIKit calls
    /// this again whenever the page, the session or the export state changes.
    override func updateProperties() {
//        super.updateProperties()
//        navigationItem.title = notebookTitle
//
//        let page = coordinator.currentPageIndex + 1
//        pageCounterLabel.text = "\(page) / \(coordinator.totalPages)"
//        pageCounterLabel.accessibilityLabel = "Page \(page) of \(coordinator.totalPages)"
//        pageCounterLabel.sizeToFit()
//        deletePageItem.isEnabled = coordinator.canDeleteCurrentPage
//
        paneButton.accessibilityLabel =
            showingMaterialPane ? "Hide Material" : "Open Material Beside Notes"
        paneButton.configuration?.image = UIImage(
            systemName: showingMaterialPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
//
//        exportOverlay.isHidden = !coordinator.isExporting
    }

    /// "W3 · Mon" for one session; "Lectures · W3 · Mon" for a whole section, where the
    /// second half follows the page being read.
    private var notebookTitle: String {
        switch route.scope {
        case .session(let id):
            return document.manifest.sessions.first { $0.id == id }
                .map { document.manifest.title(for: $0) } ?? "Notebook"
        case .section(let id):
            let name = document.manifest.section(withID: id)?.name ?? "Notebook"
            return [name, coordinator.currentSessionTitle].compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    // MARK: - Layout

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layoutSplit()
    }

    /// Notebook and material side by side. The notebook is the same child whether the
    /// pane is open or not — the pane is an optional sibling on one side or the other —
    /// so opening, closing or moving the pane never rebuilds the canvas (which would
    /// drop its scroll position, zoom and any unsaved ink).
    ///
    /// The notebook covers the full height (it scrolls under the bars); the pane sits
    /// in the safe area, and the divider runs from under the top bar to the bottom edge.
    private func layoutSplit() {
        placeNotebookAndPane()
        layoutChrome()
    }

    private func placeNotebookAndPane() {
        let bounds = view.bounds
        guard let pane = inlinePane else {
            notebook.view.frame = bounds
            divider.isHidden = true
            return
        }
        let safe = view.safeAreaInsets
        let total = bounds.width
        let paneWidth = (total * clampedFraction(paneFraction)).rounded()
        let rest = total - paneWidth - Self.dividerWidth
        let paneHeight = bounds.height - safe.top - safe.bottom
        let dividerHeight = bounds.height - safe.top

        if paneIsOnLeft {
            pane.view.frame = CGRect(x: 0, y: safe.top, width: paneWidth, height: paneHeight)
            divider.frame = CGRect(
                x: paneWidth, y: safe.top, width: Self.dividerWidth, height: dividerHeight)
            notebook.view.frame = CGRect(
                x: paneWidth + Self.dividerWidth, y: 0, width: rest, height: bounds.height)
        } else {
            notebook.view.frame = CGRect(x: 0, y: 0, width: rest, height: bounds.height)
            divider.frame = CGRect(
                x: rest, y: safe.top, width: Self.dividerWidth, height: dividerHeight)
            pane.view.frame = CGRect(
                x: rest + Self.dividerWidth, y: safe.top, width: paneWidth, height: paneHeight)
        }
        divider.isHidden = false
    }
}

// MARK: - Chrome: corner buttons, rail, disk, tap to hide

extension NotebookViewController: UIGestureRecognizerDelegate {
    private func setUpChrome() {
        let stack = UIStackView(arrangedSubviews: [backButton, paneButton])
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        cornerGlass.cornerConfiguration = .capsule()
        cornerGlass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cornerGlass.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: cornerGlass.contentView.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: cornerGlass.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: cornerGlass.contentView.trailingAnchor, constant: -4),
        ])
        view.addSubview(cornerGlass)

        rail.isHidden = !showsRail
        view.addSubview(rail)

        toolbox.observe { [weak self] _ in
            self?.notebook.activateCurrentPage()
            self?.refreshTools()
        }
        notebook.onUndoStateChange = { [weak self] in self?.refreshTools() }

        // A finger tap on the page: hide / show the chrome.
        let tap = UITapGestureRecognizer(target: self, action: #selector(pageTapped(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = false
        tap.delegate = self
        notebook.view.addGestureRecognizer(tap)

        // Two fingers swiped sideways: the tool disk.
        guard showsRail else { return }
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(twoFingerSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 2
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            notebook.view.addGestureRecognizer(swipe)
        }
        // The Pencil's double-tap and squeeze are the hidden system tool picker's
        // (`PageCanvasController.activate`); the pager carries what they change into the
        // toolbox.
    }

    private func layoutChrome() {
        let notebookFrame = notebook.view.frame
        let safe = view.safeAreaInsets
        let corner = cornerGlass.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        cornerGlass.frame = CGRect(
            x: notebookFrame.minX + 10, y: safe.top + 10, width: corner.width, height: corner.height)

        let top = cornerGlass.frame.maxY + 10
        let available = view.bounds.height - safe.bottom - 10 - top
        let height = min(rail.contentHeight, max(available, 0))
        // Centred under the corner buttons' back button.
        rail.frame = CGRect(
            x: cornerGlass.frame.minX + 4 + 24 - ToolRailView.width / 2, y: top,
            width: ToolRailView.width, height: height)
        notebook.leadingObstruction =
            showsRail && !chromeHidden ? rail.frame.maxX - notebookFrame.minX : 0
    }

    private func setChromeHidden(_ hidden: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        let chrome: [UIView] = showsRail ? [cornerGlass, rail] : [cornerGlass]
        if !hidden { chrome.forEach { $0.isHidden = false } }
        UIView.animate(withDuration: 0.25) {
            chrome.forEach { $0.alpha = hidden ? 0 : 1 }
            self.setNeedsStatusBarAppearanceUpdate()
        } completion: { _ in
            if self.chromeHidden { chrome.forEach { $0.isHidden = true } }
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        view.setNeedsLayout()
    }

    @objc private func pageTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        setChromeHidden(!chromeHidden)
    }

    @objc private func twoFingerSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        toggleDisk()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Zoomed in, two fingers pan the page sideways.
        guard gestureRecognizer is UISwipeGestureRecognizer else { return true }
        return !(notebook.currentCanvas?.isZoomedIn ?? false)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    // MARK: Tools

    private func refreshTools() {
        let canUndo = notebook.canUndo
        let canRedo = notebook.canRedo
        rail.controls.show(toolbox, canUndo: canUndo, canRedo: canRedo)
        disk?.controls.show(toolbox, canUndo: canUndo, canRedo: canRedo)
    }

    private func perform(_ action: NotebookToolAction) {
        switch action {
        case .select(let kind): toolbox.select(kind)
        case .color(let color): toolbox.setColor(color)
        case .width(let level): toolbox.setWidthLevel(level)
        case .ruler: toolbox.isRulerActive.toggle()
        case .insert(let source): showInsertMenu(from: source)
        case .undo: coordinator.undo()
        case .redo: coordinator.redo()
        }
    }

    /// PaperKit's own insert menu — shapes, lines, text box — added to the page on
    /// screen. Anchored where the button was, also when that was on the disk, which
    /// closes first.
    private func showInsertMenu(from source: UIView) {
        guard let canvas = notebook.currentCanvas else { return }
        let anchor = source.convert(source.bounds, to: view)
        disk?.dismiss()
        let menu = MarkupEditViewController(supportedFeatureSet: .latest, additionalActions: [])
        menu.delegate = canvas
        menu.modalPresentationStyle = .popover
        menu.popoverPresentationController?.sourceView = view
        menu.popoverPresentationController?.sourceRect = anchor
        present(menu, animated: true)
    }

    private func toggleDisk() {
        if let disk {
            disk.dismiss()
            return
        }
        let disk = ToolDiskView { [weak self] action in self?.perform(action) }
        disk.onDismiss = { [weak self, weak disk] in
            if self?.disk === disk { self?.disk = nil }
            self?.coordinator.reclaimFocus()
        }
        disk.frame = notebook.view.frame
        disk.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(disk, belowSubview: exportOverlay)
        self.disk = disk
        refreshTools()
        disk.present()
    }
}

// MARK: - Material pane

extension NotebookViewController {
    private var paneSide: MaterialPaneSide {
        UserDefaults.standard.string(forKey: AppPreferences.Key.materialPaneSide)
            .flatMap(MaterialPaneSide.init(rawValue:)) ?? .default
    }

    /// Leading/trailing on screen: leading is the right side in a right-to-left layout.
    private var paneIsOnLeft: Bool {
        (paneSide == .leading) == (view.effectiveUserInterfaceLayoutDirection == .leftToRight)
    }

    private var paneFraction: Double {
        get {
            UserDefaults.standard.object(forKey: AppPreferences.Key.materialPaneFraction)
                as? Double ?? AppPreferences.defaultMaterialPaneFraction
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppPreferences.Key.materialPaneFraction)
        }
    }

    private var isCompact: Bool { traitCollection.horizontalSizeClass == .compact }

    private func clampedFraction(_ value: Double) -> Double {
        let range = AppPreferences.materialPaneFractionRange
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Semester week of the session being written (follows the page in a whole-section
    /// notebook); `nil` without a semester.
    private var currentWeek: Int? {
        let id: UUID?
        switch route.scope {
        case .session(let sessionID): id = sessionID
        case .section: id = coordinator.currentSessionID ?? route.initialSessionID
        }
        return document.manifest.sessions.first { $0.id == id }
            .flatMap { document.manifest.week(of: $0) }
    }

    private func toggleMaterialPane() {
        if !showingMaterialPane, paneMaterialID == nil {
            // One file: open it straight away; otherwise the pane asks which one.
            let materials = document.manifest.materialList
            if materials.count == 1 { paneMaterialID = materials[0].id }
        }
        setMaterialPaneShown(!showingMaterialPane)
    }

    private func setMaterialPaneShown(_ shown: Bool) {
        guard shown != showingMaterialPane else { return }
        showingMaterialPane = shown
        setNeedsUpdateProperties()
        placePane(animated: true)
    }

    /// Puts the pane where it belongs for `showingMaterialPane` and the size class:
    /// beside the notebook, in a sheet, or nowhere. Also runs when the size class changes.
    private func placePane(animated: Bool) {
        let wantsInline = showingMaterialPane && !isCompact
        let wantsSheet = showingMaterialPane && isCompact

        if !wantsSheet, let sheetPane {
            self.sheetPane = nil
            sheetPane.dismiss(animated: animated)
        }
        if wantsSheet, sheetPane == nil {
            let pane = makePane(inline: false)
            pane.presentationController?.delegate = self
            sheetPane = pane
            present(pane, animated: animated)
        }

        if wantsInline, inlinePane == nil {
            let pane = makePane(inline: true)
            addChild(pane)
            view.insertSubview(pane.view, belowSubview: divider)
            pane.didMove(toParent: self)
            inlinePane = pane
            pane.view.alpha = 0
            layoutSplit()
            animateLayout(animated, changes: { pane.view.alpha = 1 })
        } else if !wantsInline, let pane = inlinePane {
            inlinePane = nil
            pane.willMove(toParent: nil)
            animateLayout(animated, changes: { pane.view.alpha = 0 }) {
                pane.view.removeFromSuperview()
                pane.removeFromParent()
            }
        }
    }

    /// Re-lays out the split (in a spring animation when `animated`), then gives the
    /// tool picker back: opening or closing the pane moves first responder.
    private func animateLayout(
        _ animated: Bool, changes: @escaping () -> Void = {}, completion: @escaping () -> Void = {}
    ) {
        let update = {
            changes()
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        let finish = { [weak self] in
            completion()
            self?.coordinator.reclaimFocus()
        }
        guard animated else {
            update()
            finish()
            return
        }
        UIView.animate(
            withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
            animations: update, completion: { _ in finish() })
    }

    private func makePane(inline: Bool) -> MaterialPaneViewController {
        let pane = MaterialPaneViewController(document: document) { [weak self] in
            self?.currentWeek
        }
        pane.materialID = paneMaterialID
        pane.onMaterialChange = { [weak self] id in self?.paneMaterialID = id }
        pane.onClose = { [weak self] in self?.setMaterialPaneShown(false) }
        pane.onAdd = { [weak self] in self?.showMaterialImporter() }
        if inline {
            pane.onContentShown = { [weak self] in self?.coordinator.reclaimFocus() }
        }
        return pane
    }

    @objc private func dividerPanned(_ recognizer: UIPanGestureRecognizer) {
        let total = view.bounds.width
        guard total > 0 else { return }
        switch recognizer.state {
        case .began, .changed:
            let x = recognizer.location(in: view).x / total
            let fraction = clampedFraction(paneIsOnLeft ? x : 1 - x)
            dragFraction = fraction
            let lineX = (paneIsOnLeft ? fraction : 1 - fraction) * total
            dragIndicator.frame = CGRect(x: lineX - 1.5, y: 0, width: 3, height: view.bounds.height)
            dragIndicator.isHidden = false
        case .ended:
            if let dragFraction { paneFraction = dragFraction }
            fallthrough
        default:
            dragFraction = nil
            dragIndicator.isHidden = true
            view.setNeedsLayout()
        }
    }

    // MARK: Adding material

    private func showMaterialImporter() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        (presentedViewController ?? self).present(picker, animated: true)
    }

    /// Files the picked files under the current week and shows the first beside the notes.
    private func addMaterials(from urls: [URL]) {
        let week = currentWeek
        Task {
            let result = await document.importMaterials(at: urls, securityScoped: true, week: week)
            if let message = result.errorMessage {
                showAlert(title: "Couldn't Add File", message: message)
            }
            guard let first = result.added.first else { return }
            paneMaterialID = first.id
            inlinePane?.materialID = first.id
            sheetPane?.materialID = first.id
            setMaterialPaneShown(true)
        }
    }
}

extension NotebookViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        addMaterials(from: urls)
    }
}

extension NotebookViewController: UIAdaptivePresentationControllerDelegate {
    /// The material sheet was swiped away.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === sheetPane else { return }
        sheetPane = nil
        showingMaterialPane = false
        setNeedsUpdateProperties()
        coordinator.reclaimFocus()
    }
}

// MARK: - Pages, export, alerts

extension NotebookViewController {
    private func confirmDeletePage() {
        let alert = UIAlertController(
            title: "Delete Page \(coordinator.currentPageIndex + 1)?",
            message: "The page and everything written on it will be permanently deleted.",
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.coordinator.deleteCurrentPage()
            })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showExportOptions() {
        let sheet = UINavigationController(
            rootViewController: PDFExportViewController(
                document: document, notebookTitle: notebookTitle, coordinator: coordinator))
        sheet.modalPresentationStyle = .formSheet
        present(sheet, animated: true)
    }

    /// The share sheet for a generated PDF — a popover from the Export button, which
    /// iPad requires (it crashes without a source).
    private func share(_ url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
//        activity.popoverPresentationController?.sourceItem = exportItem
        if let presented = presentedViewController {
            presented.dismiss(animated: true) { [weak self] in
                self?.present(activity, animated: true)
            }
        } else {
            present(activity, animated: true)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        (presentedViewController ?? self).present(alert, animated: true)
    }
}

// MARK: - Views

/// The handle between the notebook and the material pane: a hairline and a grip.
private final class PaneDivider: UIView {
    private let line = UIView()
    private let grip = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        line.backgroundColor = .separator
        grip.backgroundColor = .tertiaryLabel
        grip.layer.cornerRadius = 2.5
        addSubview(line)
        addSubview(grip)
        isAccessibilityElement = true
        accessibilityLabel = "Resize Material"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        grip.frame = CGRect(x: bounds.midX - 2.5, y: bounds.midY - 22, width: 5, height: 44)
    }
}

/// Dims the screen with "Exporting PDF…" while the PDF is generated.
private final class ExportingOverlay: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.35)

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        let label = UILabel()
        label.text = "Exporting PDF…"
        label.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.medium)
        label.textColor = .white
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center

        let box = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        box.layer.cornerRadius = 16
        box.clipsToBounds = true
        box.contentView.addSubview(stack)
        addSubview(box)
        for view in [box, stack] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: box.contentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: box.contentView.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: box.contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: box.contentView.trailingAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

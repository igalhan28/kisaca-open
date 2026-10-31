//
//  MaterialPaneViewController.swift
//  kisaca
//
//  A course material open beside the notebook — the script on one side, notes on the
//  other. Shown by `NotebookViewController`'s split button; which side it sits on and
//  how wide it is are device preferences (`AppPreferences`).
//
//  PDFs (the common case: scripts, exercise sheets) open in PDFKit — continuous scroll,
//  pinch zoom, text selection — at the page they were last left on
//  (`MaterialReadingPosition`). Anything else (slides, images, documents) opens in an
//  embedded Quick Look view. Markup is deliberately not offered here: it is Quick Look's
//  full-screen feature, reached from the Materials list (`MaterialPreviewer`), and the
//  pencil on this screen belongs to the notebook.
//

import PDFKit
import QuickLook
import UIKit
import UniformTypeIdentifiers

final class MaterialPaneViewController: UIViewController {
    private let document: LectureDocument
    /// Week of the session being written — its materials are listed first. Read in
    /// `updateProperties`, so the list re-sorts when it changes.
    private let currentWeek: () -> Int?

    /// The material shown; `nil` shows a picker.
    var materialID: UUID? {
        didSet {
            guard materialID != oldValue else { return }
            onMaterialChange(materialID)
            loadMaterial()
        }
    }
    var onMaterialChange: (UUID?) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// Opens the file picker to add material without leaving the notebook.
    var onAdd: () -> Void = {}
    /// Called once a material is on screen. Showing a PDF can take first responder (and
    /// with it the notebook's tool picker); the notebook uses this to take it back.
    var onContentShown: () -> Void = {}

    private enum LoadedContent {
        case pdf(PDFDocument)
        case file(URL)
        case failed(String)
    }

    /// What the content area shows — content is only rebuilt when this changes.
    private enum Display: Equatable {
        case empty, picker, loading(UUID), pdf(UUID), file(UUID), failed(UUID)
    }

    private var loaded: LoadedContent?
    private var loadTask: Task<Void, Never>?
    private var display: Display?

    private let headerButton = UIButton(configuration: .plain())
    private let contentArea = UIView()
    private var contentView: UIView?
    private var quickLook: QLPreviewController?
    private let quickLookSource = QuickLookSource()
    private var picker: UICollectionView?
    private var pickerSource: UICollectionViewDiffableDataSource<Int, UUID>?

    init(document: LectureDocument, currentWeek: @escaping () -> Int?) {
        self.document = document
        self.currentWeek = currentWeek
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Materials

    /// This week's files, then the whole lecture's, then other weeks; newest first within.
    private var materials: [CourseMaterial] {
        let week = currentWeek()
        func rank(_ m: CourseMaterial) -> Int {
            if let materialWeek = m.week { return materialWeek == week ? 0 : 2 }
            return 1
        }
        return document.manifest.materialList.sorted {
            (rank($0), $1.addedAt) < (rank($1), $0.addedAt)
        }
    }

    private var material: CourseMaterial? {
        materialID.flatMap { id in document.manifest.materialList.first { $0.id == id } }
    }

    private func label(for item: CourseMaterial) -> String {
        item.week.map { "\(item.title) · W\($0)" } ?? item.title
    }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        headerButton.showsMenuAsPrimaryAction = true
        headerButton.configuration?.imagePadding = 6
        headerButton.configuration?.indicator = .popup
        headerButton.configuration?.titleLineBreakMode = .byTruncatingTail
        headerButton.configuration?.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.medium)
            return attributes
        }
        headerButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let addButton = iconButton("plus", label: "Add Material") { [weak self] in self?.onAdd() }
        let closeButton = iconButton("xmark", label: "Close Material") { [weak self] in
            self?.onClose()
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [headerButton, spacer, addButton, closeButton])
        header.spacing = 8
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8, leading: 12, bottom: 8, trailing: 12)

        let divider = UIView()
        divider.backgroundColor = .separator

        for subview in [header, divider, contentArea] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
            contentArea.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        loadMaterial()
    }

    /// Reads the lecture's materials (and the current week), so UIKit calls this again
    /// whenever they change: the menu and picker stay current, and a shown material
    /// that was deleted falls back to the picker.
    override func updateProperties() {
        super.updateProperties()
        let materials = materials
        let current = material

        var configuration = headerButton.configuration
        configuration?.title = current?.title ?? "Materials"
        configuration?.image = UIImage(systemName: current?.symbolName ?? "tray.full")
        headerButton.configuration = configuration
        headerButton.isEnabled = !materials.isEmpty
        headerButton.menu = UIMenu(
            children: materials.map { item in
                UIAction(
                    title: label(for: item), image: UIImage(systemName: item.symbolName),
                    state: item.id == current?.id ? .on : .off
                ) { [weak self] _ in self?.materialID = item.id }
            })

        showContent(materials: materials)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void)
        -> UIButton
    {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline)
                .applying(UIImage.SymbolConfiguration(weight: .semibold)))
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }

    // MARK: - Content

    private func showContent(materials: [CourseMaterial]) {
        let next: Display
        if materials.isEmpty {
            next = .empty
        } else if let material {
            switch loaded {
            case .none: next = .loading(material.id)
            case .pdf: next = .pdf(material.id)
            case .file: next = .file(material.id)
            case .failed: next = .failed(material.id)
            }
        } else {
            next = .picker
        }

        if next == .picker, display == .picker {
            applyPickerSnapshot(materials)
            return
        }
        guard next != display else { return }
        display = next
        removeContent()

        switch (next, loaded) {
        case (.empty, _):
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "tray")
            configuration.text = "No Materials"
            configuration.secondaryText = "Add scripts and slides to read them here while you write."
            var button = UIButton.Configuration.borderedProminent()
            button.title = "Add Material"
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onAdd() }
            install(UIContentUnavailableView(configuration: configuration))
        case (.picker, _):
            install(makePicker())
            applyPickerSnapshot(materials)
        case (.pdf(let id), .pdf(let pdf)):
            // Opens where this PDF was last left, here or full screen.
            let pdfView = ResumingPDFView(document: pdf, materialID: id)
            pdfView.backgroundColor = .secondarySystemBackground
            install(pdfView)
        case (.file, .file(let url)):
            quickLookSource.url = url
            let controller = QLPreviewController()
            controller.dataSource = quickLookSource
            addChild(controller)
            install(controller.view)
            controller.didMove(toParent: self)
            quickLook = controller
        case (.failed, .failed(let message)):
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            configuration.text = "Can't Open"
            configuration.secondaryText = message
            install(UIContentUnavailableView(configuration: configuration))
        default:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            install(spinner)
        }
    }

    private func install(_ subview: UIView) {
        subview.frame = contentArea.bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentArea.addSubview(subview)
        contentView = subview
    }

    private func removeContent() {
        if let quickLook {
            quickLook.willMove(toParent: nil)
            quickLook.view.removeFromSuperview()
            quickLook.removeFromParent()
            self.quickLook = nil
        }
        contentView?.removeFromSuperview()
        contentView = nil
        picker = nil
        pickerSource = nil
    }

    // MARK: - Picker

    private func makePicker() -> UICollectionView {
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.backgroundColor = .clear
        let collection = UICollectionView(
            frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list))
        collection.backgroundColor = .clear
        collection.delegate = self

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> {
            [weak self] cell, _, id in
            guard let self, let item = document.manifest.materialList.first(where: { $0.id == id })
            else { return }
            var content = cell.defaultContentConfiguration()
            content.text = label(for: item)
            content.image = UIImage(systemName: item.symbolName)
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.backgroundConfiguration = .clear()
        }
        pickerSource = UICollectionViewDiffableDataSource(collectionView: collection) {
            collection, indexPath, id in
            collection.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        picker = collection
        return collection
    }

    private func applyPickerSnapshot(_ materials: [CourseMaterial]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(materials.map(\.id))
        snapshot.reconfigureItems(materials.map(\.id))
        pickerSource?.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Loading

    private func loadMaterial() {
        loadTask?.cancel()
        loaded = nil
        setNeedsUpdateProperties()
        guard isViewLoaded, let material else { return }
        loadTask = Task { [weak self] in await self?.load(material) }
    }

    private func load(_ material: CourseMaterial) async {
        guard let data = await document.materialData(for: material) else {
            finish(.failed("\"\(material.title)\" couldn't be read from the lecture file."))
            return
        }
        guard !Task.isCancelled else { return }
        if material.contentType?.conforms(to: .pdf) == true, let pdf = PDFDocument(data: data) {
            finish(.pdf(pdf))
        } else {
            do {
                finish(.file(try MaterialFiles.temporaryCopy(of: material, data: data)))
            } catch {
                finish(.failed(error.localizedDescription))
                return
            }
        }
        // After the view has been installed, which is when it would take first responder.
        try? await Task.sleep(for: .milliseconds(300))
        if !Task.isCancelled { onContentShown() }
    }

    private func finish(_ content: LoadedContent) {
        guard !Task.isCancelled else { return }
        loaded = content
        setNeedsUpdateProperties()
    }
}

extension MaterialPaneViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        materialID = pickerSource?.itemIdentifier(for: indexPath)
    }
}

// MARK: - Quick Look (embedded)

private final class QuickLookSource: NSObject, QLPreviewControllerDataSource {
    var url: URL?

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { url == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
        -> any QLPreviewItem
    {
        (url ?? URL(fileURLWithPath: "/")) as NSURL
    }
}

extension UIFont {
    /// This font at `weight`, keeping its size (and Dynamic Type scaling).
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

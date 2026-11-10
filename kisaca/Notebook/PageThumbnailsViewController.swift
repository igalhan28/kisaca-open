//
//  PageThumbnailsViewController.swift
//  kisaca
//
//  The Pages applet (2026-11-10): every page of the open notebook as a thumbnail,
//  opened from the sidebar beside the notes. Tap one to go straight to that page — no
//  page-curl, no paging through everything in between. The page on screen is
//  outlined and kept in view; in a whole-section notebook the pages are grouped under
//  their session ("W3 · Mon").
//
//  Thumbnails are the saved ink-only PNGs (`PageRepository.saveThumbnail`) laid over
//  a live grid, like the home screen's cards. The page on screen gets a fresh one when
//  the panel opens (the notebook flushes it) and on every autosave after that; this
//  view follows `LectureDocument.pageContentRevision`, and the coordinator's page
//  index and count, through `updateProperties`.
//
//  Hosted by `NotebookViewController` (see "Applet panels" there, and docs/sidebar.md).
//

import ImageIO
import UIKit

final class PageThumbnailsViewController: UIViewController {
    /// The panel's width beside the notes: one column of thumbnails.
    static let preferredWidth: CGFloat = 196

    private let document: LectureDocument
    private let repository: PageRepository
    private let coordinator: NotebookCoordinator

    /// A thumbnail was tapped: the index of its page in the notebook.
    var onSelectPage: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// Adds a page after the current one; `nil` hides the button (iPhone reads only).
    var onAddPage: (() -> Void)?

    private let countLabel = UILabel()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<UUID, UUID>!

    // What the list shows, to tell what changed when `updateProperties` runs again.
    private var shownPageIDs: [UUID] = []
    private var pageNumbers: [UUID: Int] = [:]
    private var gridSpacings: [UUID: CGFloat] = [:]
    private var shownRevision = -1
    private var shownCurrent: UUID?
    private var showsSessionHeaders = false

    /// Decoded thumbnails, with the bytes they came from: reconfiguring a tile whose
    /// thumbnail hasn't changed reuses the image instead of decoding it again.
    private var images: [UUID: (data: Data, image: UIImage)] = [:]

    init(document: LectureDocument, repository: PageRepository, coordinator: NotebookCoordinator) {
        self.document = document
        self.repository = repository
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        let title = UILabel()
        title.text = "Pages"
        title.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        countLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        countLabel.textColor = .secondaryLabel
        let titles = UIStackView(arrangedSubviews: [title, countLabel])
        titles.axis = .vertical
        titles.spacing = 1
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var buttons: [UIView] = []
        if let onAddPage {
            buttons.append(iconButton("plus", label: "Add Page") { onAddPage() })
        }
        buttons.append(iconButton("xmark", label: "Close Pages") { [weak self] in self?.onClose() })
        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [titles, spacer] + buttons)
        header.spacing = 8
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8, leading: 14, bottom: 8, trailing: 10)

        let rule = UIView()
        rule.backgroundColor = .separator

        collection.backgroundColor = .clear
        collection.delegate = self
        collection.register(ThumbnailTile.self, forCellWithReuseIdentifier: ThumbnailTile.reuseID)
        collection.register(
            SessionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: SessionHeader.reuseID)
        dataSource = UICollectionViewDiffableDataSource(collectionView: collection) {
            [weak self] collectionView, indexPath, pageID in
            let tile = collectionView.dequeueReusableCell(
                withReuseIdentifier: ThumbnailTile.reuseID, for: indexPath) as! ThumbnailTile
            self?.configure(tile, for: pageID)
            return tile
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: SessionHeader.reuseID, for: indexPath) as! SessionHeader
            header.title = self?.sessionTitle(forSection: indexPath.section)
            return header
        }

        for subview in [header, rule, collection] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
            collection.topAnchor.constraint(equalTo: rule.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToCurrent(animated: false)
    }

    /// Reads the pages (the manifest), the page on screen and the thumbnails' revision,
    /// so UIKit calls this again whenever any of them changes.
    override func updateProperties() {
        super.updateProperties()
        let pageIDs = repository.pageIDs
        let revision = document.pageContentRevision
        let currentIndex = coordinator.currentPageIndex
        let current = pageIDs.indices.contains(currentIndex) ? pageIDs[currentIndex] : nil

        countLabel.text = pageIDs.isEmpty
            ? "No pages" : "\(min(currentIndex + 1, pageIDs.count)) of \(pageIDs.count)"

        if pageIDs != shownPageIDs {
            shownRevision = revision
            shownCurrent = current
            applySnapshot(pageIDs: pageIDs)
            scrollToCurrent(animated: false)
            return
        }
        var changed: Set<UUID> = []
        if revision != shownRevision {
            // A thumbnail or a page's ink changed; tiles whose bytes didn't reuse their image.
            shownRevision = revision
            changed.formUnion(pageIDs)
        }
        if current != shownCurrent {
            changed.formUnion([shownCurrent, current].compactMap { $0 })
            shownCurrent = current
            scrollToCurrent(animated: true)
        }
        guard !changed.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(changed.contains))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Data

    private func applySnapshot(pageIDs: [UUID]) {
        shownPageIDs = pageIDs
        pageNumbers = Dictionary(uniqueKeysWithValues: pageIDs.enumerated().map { ($1, $0 + 1) })
        gridSpacings = Dictionary(
            uniqueKeysWithValues: pageIDs.indices.map { (pageIDs[$0], repository.gridSpacing(forPageAt: $0)) })
        images = images.filter { pageNumbers[$0.key] != nil }

        let groups = repository.pageGroups.filter { !$0.pageIDs.isEmpty }
        let headers = groups.count > 1
        if headers != showsSessionHeaders {
            showsSessionHeaders = headers
            collection.collectionViewLayout.invalidateLayout()
        }
        var snapshot = NSDiffableDataSourceSnapshot<UUID, UUID>()
        for group in groups {
            snapshot.appendSections([group.session.id])
            snapshot.appendItems(group.pageIDs, toSection: group.session.id)
        }
        // Headers carry the session's title, which a reload of the same IDs wouldn't redo.
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func sessionTitle(forSection section: Int) -> String? {
        let ids = dataSource.snapshot().sectionIdentifiers
        guard ids.indices.contains(section),
            let session = document.manifest.sessions.first(where: { $0.id == ids[section] })
        else { return nil }
        return document.manifest.title(for: session)
    }

    private func configure(_ tile: ThumbnailTile, for pageID: UUID) {
        let number = pageNumbers[pageID] ?? 0
        tile.show(
            pageID: pageID, number: number, gridSpacing: gridSpacings[pageID] ?? 0,
            isCurrent: pageID == shownCurrent)

        guard let data = document.getThumbnailData(for: pageID) else {
            tile.setInk(nil, for: pageID)
            return
        }
        if let cached = images[pageID], cached.data == data {
            tile.setInk(cached.image, for: pageID)
            return
        }
        // Decoded off the main thread, downsampled to the tile — a saved thumbnail is
        // far larger than a tile (see `PageRepository.loadThumbnail`). The tile keeps
        // its old image until then, so an updated thumbnail doesn't flash.
        let maxPixels = Self.preferredWidth * 3 * PageGeometry.a4Size.height / PageGeometry.a4Size.width
        tile.loadTask?.cancel()
        tile.loadTask = Task { [weak self, weak tile] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.downsampled(data, maxPixels: maxPixels)
            }.value
            guard !Task.isCancelled, let self, let image else { return }
            images[pageID] = (data, image)
            tile?.setInk(image, for: pageID)
        }
    }

    private nonisolated static func downsampled(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// Brings the page on screen into view, unless it already is.
    private func scrollToCurrent(animated: Bool) {
        guard let current = shownCurrent, let indexPath = dataSource.indexPath(for: current) else { return }
        collection.layoutIfNeeded()
        guard let frame = collection.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let visible = collection.bounds.inset(by: collection.adjustedContentInset)
        if !visible.contains(frame) {
            collection.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
        }
    }

    // MARK: - Layout

    /// One column in the panel; more side by side when it is wider (a sheet on iPhone).
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            let inset: CGFloat = 16
            let spacing: CGFloat = 14
            let available = environment.container.effectiveContentSize.width - 2 * inset
            let columns = max(1, Int((available + spacing) / (180 + spacing)))
            let tileWidth = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let height = ThumbnailTile.height(forWidth: max(tileWidth, 40))

            let item = NSCollectionLayoutItem(
                layoutSize: .init(widthDimension: .absolute(max(tileWidth, 40)), heightDimension: .absolute(height)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: inset, bottom: 16, trailing: inset)
            if self?.showsSessionHeaders == true {
                // Edge to edge, so the pinned header hides the tiles scrolling under it.
                section.supplementariesFollowContentInsets = false
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(30)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                header.pinToVisibleBounds = true
                section.boundarySupplementaryItems = [header]
            }
            return section
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
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
}

extension PageThumbnailsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let pageID = dataSource.itemIdentifier(for: indexPath),
            let number = pageNumbers[pageID]
        else { return }
        onSelectPage(number - 1)
    }
}

// MARK: - Tile

/// One page: cream paper with its grid, the ink thumbnail on top, its number below.
/// The page on screen is outlined in the tint colour.
private final class ThumbnailTile: UICollectionViewCell {
    static let reuseID = "ThumbnailTile"
    private static let labelHeight: CGFloat = 22

    static func height(forWidth width: CGFloat) -> CGFloat {
        (width * PageGeometry.a4Size.height / PageGeometry.a4Size.width).rounded() + labelHeight
    }

    private let paper = UIView()
    private let grid = UIGridBackgroundView()
    private let ink = UIImageView()
    private let number = UILabel()
    private var pageID: UUID?
    private var isCurrent = false
    var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        paper.backgroundColor = UIColor(hex: 0xFFFCFA)
        paper.layer.cornerRadius = 4
        paper.layer.cornerCurve = .continuous
        paper.clipsToBounds = true
        grid.isUserInteractionEnabled = false
        ink.contentMode = .scaleToFill
        paper.addSubview(grid)
        paper.addSubview(ink)
        number.textAlignment = .center
        contentView.addSubview(paper)
        contentView.addSubview(number)
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ThumbnailTile, _) in
            self.updateOutline()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        paper.frame = CGRect(
            x: 0, y: 0, width: width,
            height: (width * PageGeometry.a4Size.height / PageGeometry.a4Size.width).rounded())
        grid.frame = paper.bounds
        grid.pageScale = width / PageGeometry.a4Size.width
        ink.frame = paper.bounds
        number.frame = CGRect(x: 0, y: paper.frame.maxY, width: width, height: Self.labelHeight)
    }

    override var isHighlighted: Bool {
        didSet { paper.alpha = isHighlighted ? 0.7 : 1 }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
    }

    func show(pageID: UUID, number: Int, gridSpacing: CGFloat, isCurrent: Bool) {
        if self.pageID != pageID {
            // A different page: its ink comes separately; don't show the last one's.
            ink.image = nil
            loadTask?.cancel()
        }
        self.pageID = pageID
        self.isCurrent = isCurrent
        if gridSpacing > 0 { grid.spacing = gridSpacing }
        self.number.text = "\(number)"
        self.number.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: isCurrent ? .bold : .regular)
        self.number.textColor = isCurrent ? .tintColor : .secondaryLabel
        accessibilityLabel = "Page \(number)"
        accessibilityTraits = isCurrent ? [.button, .selected] : .button
        accessibilityHint = isCurrent ? nil : "Goes to this page."
        updateOutline()
    }

    func setInk(_ image: UIImage?, for pageID: UUID) {
        guard pageID == self.pageID else { return }
        ink.image = image
    }

    private func updateOutline() {
        paper.layer.borderWidth = isCurrent ? 2.5 : 1 / max(traitCollection.displayScale, 1)
        paper.layer.borderColor = (isCurrent ? UIColor.tintColor : UIColor.separator)
            .resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - Session header

/// "W3 · Mon" above a session's pages in a whole-section notebook; stays pinned while
/// its pages scroll past.
private final class SessionHeader: UICollectionReusableView {
    static let reuseID = "SessionHeader"
    private let label = UILabel()

    var title: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        label.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

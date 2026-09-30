//
//  LibraryViewController.swift
//  kisaca
//
//  The home screen: what's coming up and what just happened across every lecture, then
//  each lecture with its own sessions — one shelf per row, scrolling sideways. Tapping a
//  session opens its notebook; tapping a lecture's name opens the lecture, holding it
//  offers Open / Delete. See docs/library.md. Was the SwiftUI `LibraryHomeView` before
//  the UIKit migration (docs/uikit-migration.md).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class LibraryViewController: UICollectionViewController {
    private let library: LectureLibrary

    var onOpen: (LectureEntry, _ session: UUID?) -> Void = { _, _ in }
    var onCreate: () -> Void = {}
    /// After an import, with the new files' URLs.
    var onImported: ([URL]) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    /// The entry being opened (`LectureEntry.id`, or "new"), so its card can show
    /// progress and New Lecture is disabled meanwhile. Set by `AppCoordinator`.
    var openingID: String? {
        didSet { setNeedsUpdateProperties() }
    }

    nonisolated enum Shelf: Hashable {
        case upcoming
        case recent
        case lecture(String)
    }

    nonisolated enum Item: Hashable {
        /// `SessionItem.id`; the shelf is part of it because a session can be on two shelves.
        case session(shelf: Shelf, id: String)
        /// A lecture with nothing to show yet, by `LectureEntry.id`.
        case placeholder(String)
    }

    private var dataSource: UICollectionViewDiffableDataSource<Shelf, Item>!
    /// What the cards on screen show, rebuilt with every snapshot.
    private var sessionItems: [String: SessionItem] = [:]
    private var entries: [String: LectureEntry] = [:]
    /// Lectures whose shelf has been moved to the session nearest today — once each.
    private var positionedShelves: Set<String> = []
    /// Per lecture, the session to open its shelf at.
    private var initialItems: [String: Item] = [:]

    private lazy var newLectureItem = UIBarButtonItem(
        title: "New Lecture", image: UIImage(systemName: "plus"),
        primaryAction: UIAction { [weak self] _ in self?.onCreate() })

    init(library: LectureLibrary) {
        self.library = library
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "KISACA"
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItems = [
            newLectureItem,
            UIBarButtonItem(
                title: "Import", image: UIImage(systemName: "square.and.arrow.down"),
                primaryAction: UIAction { [weak self] _ in self?.showImporter() }),
            UIBarButtonItem(
                title: "Settings", image: UIImage(systemName: "gearshape"),
                primaryAction: UIAction { [weak self] _ in self?.showSettings() }),
        ]

        collectionView.collectionViewLayout = makeLayout()
        collectionView.register(SessionCardCell.self, forCellWithReuseIdentifier: SessionCardCell.reuseID)
        collectionView.register(
            PlaceholderCardCell.self, forCellWithReuseIdentifier: PlaceholderCardCell.reuseID)
        configureDataSource()
    }

    /// Reads the library (and the opening state), so UIKit calls this again whenever a
    /// lecture is added, removed, downloaded or changed on disk.
    override func updateProperties() {
        super.updateProperties()
        newLectureItem.isEnabled = openingID == nil

        var snapshot = NSDiffableDataSourceSnapshot<Shelf, Item>()
        sessionItems = [:]
        entries = [:]
        initialItems = [:]

        func add(_ shelf: Shelf, _ items: [SessionItem]) {
            snapshot.appendSections([shelf])
            snapshot.appendItems(items.map { .session(shelf: shelf, id: $0.id) })
            for item in items { sessionItems[item.id] = item }
        }

        let upcoming = library.upcomingSessions()
        let recent = library.recentSessions()
        if !upcoming.isEmpty { add(.upcoming, upcoming) }
        if !recent.isEmpty { add(.recent, recent) }

        let startOfToday = Calendar.current.startOfDay(for: Date())
        for entry in library.entries {
            entries[entry.id] = entry
            let shelf = Shelf.lecture(entry.id)
            let sessions = library.sessions(of: entry)
            if sessions.isEmpty {
                snapshot.appendSections([shelf])
                snapshot.appendItems([.placeholder(entry.id)])
            } else {
                add(shelf, sessions)
                // Opens at the session nearest today, so the row shows what's current
                // rather than week 1.
                let current = sessions.first { $0.session.date >= startOfToday } ?? sessions.last
                if let current { initialItems[entry.id] = .session(shelf: shelf, id: current.id) }
            }
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)

        if library.hasLoaded, library.entries.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "books.vertical")
            empty.text = "No Lectures Yet"
            empty.secondaryText = "Create a lecture, or import .kisaca files you already have."
            var create = UIButton.Configuration.borderedProminent()
            create.title = "New Lecture"
            empty.button = create
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.onCreate() }
            var importButton = UIButton.Configuration.plain()
            importButton.title = "Import…"
            empty.secondaryButton = importButton
            empty.secondaryButtonProperties.primaryAction = UIAction { [weak self] _ in
                self?.showImporter()
            }
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionShelves()
    }

    /// Moves each lecture's shelf to the session nearest today, once — after that the
    /// row is the user's. Waits until the collection view holds the snapshot: asking for
    /// an item's position earlier throws (see SectionSessionsViewController).
    private func positionShelves() {
        guard view.window != nil else { return }
        let snapshot = dataSource.snapshot()
        guard collectionView.numberOfSections == snapshot.numberOfSections else { return }
        for (entryID, item) in initialItems where !positionedShelves.contains(entryID) {
            positionedShelves.insert(entryID)
            guard let indexPath = dataSource.indexPath(for: item), indexPath.item > 0 else { continue }
            collectionView.scrollToItem(at: indexPath, at: .left, animated: false)
        }
    }

    // MARK: - Layout and cells

    private func makeLayout() -> UICollectionViewLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 32
        return UICollectionViewCompositionalLayout(
            sectionProvider: { _, _ in
                let item = NSCollectionLayoutItem(
                    layoutSize: .init(
                        widthDimension: .absolute(SessionCardMetrics.width),
                        heightDimension: .absolute(SessionCardMetrics.height)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: item.layoutSize, subitems: [item])
                let section = NSCollectionLayoutSection(group: group)
                section.orthogonalScrollingBehavior = .continuous
                section.interGroupSpacing = 16
                section.contentInsets = .init(top: 12, leading: 20, bottom: 0, trailing: 20)
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(34)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                // The section's own insets already line it up with the cards.
                section.boundarySupplementaryItems = [header]
                return section
            }, configuration: configuration)
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            guard let self else { return nil }
            switch item {
            case .session(let shelf, let id):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SessionCardCell.reuseID, for: indexPath) as! SessionCardCell
                if let session = sessionItems[id] {
                    let isLectureShelf = if case .lecture = shelf { true } else { false }
                    cell.configure(
                        with: session, showsLecture: !isLectureShelf, emphasizesDay: shelf == .upcoming,
                        isOpening: openingID == session.lecture.id)
                }
                return cell
            case .placeholder(let entryID):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PlaceholderCardCell.reuseID, for: indexPath) as! PlaceholderCardCell
                if let entry = entries[entryID] {
                    cell.configure(with: entry, isOpening: openingID == entryID)
                }
                return cell
            }
        }

        let header = UICollectionView.SupplementaryRegistration<ShelfHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            switch dataSource.sectionIdentifier(for: indexPath.section) {
            case .upcoming: view.showTitle("Upcoming Sessions")
            case .recent: view.showTitle("Last Sessions")
            case .lecture(let id):
                guard let entry = entries[id] else { return }
                view.showLecture(
                    entry, showsLocalOnly: !entry.isInICloud && library.usesICloud,
                    onOpen: { [weak self] in self?.onOpen(entry, nil) },
                    onDelete: { [weak self, weak view] in
                        self?.confirmDelete(entry, from: view)
                    })
            case nil: break
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    // MARK: - Selection and menus

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .session(_, let id):
            if let item = sessionItems[id] { onOpen(item.lecture, item.session.id) }
        case .placeholder(let id):
            if let entry = entries[id] { onOpen(entry, nil) }
        case nil:
            break
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, case .session(_, let id) = dataSource.itemIdentifier(for: indexPaths[0]),
            let item = sessionItems[id]
        else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Open Lecture", image: UIImage(systemName: "book")) { _ in
                    self?.onOpen(item.lecture, nil)
                }
            ])
        })
    }

    // MARK: - Actions

    private func showSettings() {
        present(UIHostingController(rootView: LibrarySettingsView().environment(library)), animated: true)
    }

    private func showImporter() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.kisacaLecture], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func confirmDelete(_ entry: LectureEntry, from source: UIView?) {
        let sheet = UIAlertController(
            title: "Delete “\(entry.name)”?",
            message: entry.isInICloud
                ? "It is deleted from iCloud and all your devices, with all its notes and materials."
                : "All its notes and materials are deleted from this device.",
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: "Delete Lecture", style: .destructive) { [weak self] _ in
                self?.delete(entry)
            })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source ?? view
            popover.sourceRect = source?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(sheet, animated: true)
    }

    private func delete(_ entry: LectureEntry) {
        Task {
            do {
                try await library.delete(entry)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

extension LibraryViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task {
            let result = await library.importLectures(from: urls)
            if !result.failed.isEmpty {
                onError("Couldn't import " + result.failed.joined(separator: ", ") + ".")
            }
            onImported(result.imported)
        }
    }
}

// MARK: - Shelf header

/// A shelf's title: plain for "Upcoming Sessions" / "Last Sessions"; for a lecture, its
/// colour dot, name and a chevron as a button — tap opens the lecture, hold for Open /
/// Delete — marked when the lecture is only on this device.
final class ShelfHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let button = UIButton(type: .system)
    /// Set per lecture; the button's actions call through these, so a reused header
    /// never keeps the previous lecture's.
    private var onOpen: () -> Void = {}
    private var onDelete: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .title2).withWeight(.bold)
        titleLabel.accessibilityTraits = .header
        button.contentHorizontalAlignment = .leading
        button.tintColor = .label
        // Tap opens the lecture; a long press shows the menu.
        button.addAction(UIAction { [weak self] _ in self?.onOpen() }, for: .primaryActionTriggered)
        button.menu = UIMenu(children: [
            UIAction(title: "Open Lecture", image: UIImage(systemName: "book")) { [weak self] _ in
                self?.onOpen()
            },
            UIAction(title: "Delete Lecture…", image: UIImage(systemName: "trash"), attributes: .destructive) {
                [weak self] _ in self?.onDelete()
            },
        ])
        for view in [titleLabel, button] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showTitle(_ title: String) {
        titleLabel.text = title
        titleLabel.isHidden = false
        button.isHidden = true
    }

    func showLecture(
        _ entry: LectureEntry, showsLocalOnly: Bool, onOpen: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        titleLabel.isHidden = true
        button.isHidden = false

        let bold = UIFont.preferredFont(forTextStyle: .title2).withWeight(.bold)
        let title = NSMutableAttributedString()
        /// An image centred on the name's capitals rather than sitting on its baseline.
        func centered(_ image: UIImage, size: CGSize? = nil) -> NSAttributedString {
            let attachment = NSTextAttachment(image: image)
            let size = size ?? image.size
            attachment.bounds = CGRect(
                x: 0, y: (bold.capHeight - size.height) / 2, width: size.width, height: size.height)
            return NSAttributedString(attachment: attachment)
        }
        func symbol(_ name: String, _ style: UIFont.TextStyle) -> UIImage {
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(textStyle: style))!
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
        }

        let dot = UIImage(systemName: "circle.fill")!.withTintColor(
            LectureColor.color(for: entry.name), renderingMode: .alwaysOriginal)
        title.append(centered(dot, size: CGSize(width: 10, height: 10)))
        title.append(NSAttributedString(string: "  " + entry.name + "  ", attributes: [.font: bold]))
        title.append(centered(symbol("chevron.right", .headline)))
        if showsLocalOnly {
            title.append(NSAttributedString(string: "  "))
            title.append(centered(symbol("icloud.slash", .subheadline)))
        }
        title.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: title.length))
        button.setAttributedTitle(title, for: .normal)
        button.accessibilityLabel = entry.name + (showsLocalOnly ? ", only on this device" : "")

        self.onOpen = onOpen
        self.onDelete = onDelete
    }
}

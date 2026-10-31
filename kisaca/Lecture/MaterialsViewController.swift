//
//  MaterialsViewController.swift
//  kisaca
//
//  The lecture's materials: scripts, slides, exercise sheets — any file the student
//  wants next to their notes. Reached from its own row at the top of the lecture's home
//  screen, the way a section's Whole Notebook sits above its sessions.
//
//  Files come in through the Files picker or by dragging them onto the list (iPad
//  multitasking), are stored inside the lecture's `.kisaca` package — so they sync and
//  move with it — and open in Quick Look, which handles PDF, Keynote/PowerPoint,
//  Pages/Word, images and plain text, and brings its own share button. Read-only:
//  materials are reference copies, notes go in the notebook (MaterialPreview.swift).
//  Was the SwiftUI `MaterialsView` before the UIKit migration (docs/uikit-migration.md).
//
//  Storage and why the bytes are not kept in memory: `LectureDocument` → Materials.
//

import PDFKit
import UIKit
import UniformTypeIdentifiers

final class MaterialsViewController: UICollectionViewController {
    private let document: LectureDocument

    /// `nil` for the whole lecture; otherwise a semester week.
    private typealias Group = Int?

    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    private let searchController = UISearchController()
    /// Retained while its preview is on screen — Quick Look holds its data source and
    /// delegate weakly.
    private var previewer: MaterialPreviewer?
    private var openingID: UUID? {
        didSet { setNeedsUpdateProperties() }
    }
    /// Where the files being picked will be filed: a week, or `nil` for the whole lecture.
    private var importWeek: Int?
    /// The groups on screen, in order — section indices of the snapshot.
    private var groups: [Group] = []

    init(document: LectureDocument) {
        self.document = document
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Newest first, filtered by the search text.
    private var materials: [CourseMaterial] {
        let all = document.manifest.materialList.sorted { $0.addedAt > $1.addedAt }
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.originalFileName.localizedCaseInsensitiveContains(query)
        }
    }

    private func material(withID id: UUID) -> CourseMaterial? {
        document.manifest.materialList.first { $0.id == id }
    }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Materials"
        navigationItem.largeTitleDisplayMode = .never

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search materials"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        collectionView.collectionViewLayout = makeLayout()
        collectionView.dropDelegate = self
        configureDataSource()
    }

    /// Reads the lecture's materials (and the weeks they can be filed under), so UIKit
    /// calls this again whenever they change.
    override func updateProperties() {
        super.updateProperties()

        let weeks = document.manifest.materialWeekChoices
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Add Files", image: UIImage(systemName: "plus"),
            menu: UIMenu(children: [
                UIAction(title: "Whole Lecture", image: UIImage(systemName: "books.vertical")) {
                    [weak self] _ in self?.addFiles(toWeek: nil)
                },
                UIMenu(
                    title: "Week…", image: UIImage(systemName: "calendar"),
                    children: weeks.map { week in
                        UIAction(title: "Week \(week)") { [weak self] _ in self?.addFiles(toWeek: week) }
                    }),
            ]))

        // Whole-lecture files first, then one group per week in order.
        let byWeek = Dictionary(grouping: materials, by: \.week)
        groups = byWeek.keys.sorted { ($0 ?? 0) < ($1 ?? 0) }
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        for (index, group) in groups.enumerated() {
            snapshot.appendSections([index])
            snapshot.appendItems((byWeek[group] ?? []).map(\.id))
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)

        if document.manifest.materialList.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "doc.on.doc")
            empty.text = "No Materials Yet"
            empty.secondaryText =
                "Add the lecture's scripts, slides and exercise sheets — from Files, or by dragging them here. File them under the whole lecture or a single week."
            var button = UIButton.Configuration.borderedProminent()
            button.title = "Add Files"
            empty.button = button
            empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.addFiles(toWeek: nil)
            }
            contentUnavailableConfiguration = empty
        } else if groups.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    // MARK: - Layout and cells

    private func makeLayout() -> UICollectionViewLayout {
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.headerMode = .supplementary
        list.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Delete") {
                [weak self] _, _, done in
                self?.confirmDelete(materialID: id)
                done(true)
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
        }
        return UICollectionViewCompositionalLayout.list(using: list)
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> {
            [weak self] cell, _, id in
            guard let self, let material = material(withID: id) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.image = UIImage(systemName: material.symbolName)
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                textStyle: .title2)
            content.imageProperties.tintColor = .tintColor
            content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 0)
            content.imageToTextPadding = 12
            content.text = material.title
            content.textProperties.numberOfLines = 2
            content.secondaryText = Self.details(of: material)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            cell.contentConfiguration = content

            if openingID == id {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
            } else {
                cell.accessories = []
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, indexPath in
            guard let self, indexPath.section < groups.count else { return }
            var content = UIListContentConfiguration.header()
            content.text = groups[indexPath.section].map { "Week \($0)" } ?? "Whole Lecture"
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// "PDF · 12.4 MB · 24 Sep 2026"
    private static func details(of material: CourseMaterial) -> String {
        let ext = (material.originalFileName as NSString).pathExtension.uppercased()
        let size = ByteCountFormatter.string(fromByteCount: Int64(material.byteCount), countStyle: .file)
        let added = material.addedAt.formatted(date: .abbreviated, time: .omitted)
        return [ext.isEmpty ? nil : ext, size, added].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Selection and menus

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let material = material(withID: id)
        else { return }
        open(material)
    }

    override func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]) else {
            return nil
        }
        let weeks = document.manifest.materialWeekChoices
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { _ in
                    self?.rename(materialID: id)
                },
                UIMenu(
                    title: "Move to", image: UIImage(systemName: "folder"),
                    children: [
                        UIAction(title: "Whole Lecture") { _ in
                            self?.document.setMaterialWeek(nil, forMaterialWithID: id)
                        }
                    ]
                        + weeks.map { week in
                            UIAction(title: "Week \(week)") { _ in
                                self?.document.setMaterialWeek(week, forMaterialWithID: id)
                            }
                        }),
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) {
                    _ in self?.confirmDelete(materialID: id)
                },
            ])
        })
    }

    // MARK: - Actions

    private func rename(materialID id: UUID) {
        guard let material = material(withID: id) else { return }
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Title"
            field.text = material.title
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
                let title = (alert?.textFields?.first?.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { self?.document.renameMaterial(withID: id, to: title) }
            })
        present(alert, animated: true)
    }

    private func confirmDelete(materialID id: UUID) {
        guard let material = material(withID: id) else { return }
        let alert = UIAlertController(
            title: "Delete \"\(material.title)\"?",
            message: "The file is removed from this lecture. This can't be undone.",
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.document.removeMaterial(withID: id)
                MaterialReadingPosition.forget(id)
            })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Couldn't Add File", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    private func addFiles(toWeek week: Int?) {
        importWeek = week
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func importFiles(at urls: [URL], securityScoped: Bool) {
        let week = importWeek
        Task {
            let result = await document.importMaterials(
                at: urls, securityScoped: securityScoped, week: week)
            if let message = result.errorMessage { showError(message) }
        }
    }

    /// Writes the file under its original name to a temporary folder and hands it to
    /// Quick Look — which needs a file URL, and shows that name in its title and when
    /// sharing. PDFs open in PDFKit instead, at the page they were left on. Read-only —
    /// see `MaterialPreviewer`.
    private func open(_ material: CourseMaterial) {
        guard openingID == nil else { return }
        openingID = material.id
        Task {
            defer { openingID = nil }
            guard let data = await document.materialData(for: material) else {
                showError("\"\(material.title)\" couldn't be read from the lecture file.")
                return
            }
            do {
                let url = try MaterialFiles.temporaryCopy(of: material, data: data)
                if material.contentType?.conforms(to: .pdf) == true, let pdf = PDFDocument(data: data) {
                    MaterialPDFReaderViewController(material: material, document: pdf, fileURL: url)
                        .present(from: self)
                    return
                }
                let previewer = MaterialPreviewer(fileURL: url, onDismiss: { [weak self] in self?.previewer = nil })
                self.previewer = previewer
                previewer.present(from: self)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }
}

extension MaterialsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        setNeedsUpdateProperties()
    }
}

extension MaterialsViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importFiles(at: urls, securityScoped: true)
    }
}

// MARK: - Drag and drop

extension MaterialsViewController: UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.item.identifier])
    }

    func collectionView(
        _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        UICollectionViewDropProposal(operation: .copy)
    }

    /// Dropped files go under the whole lecture.
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        let providers = coordinator.items.map(\.dragItem.itemProvider)
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await copyDroppedFile(from: provider) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            importWeek = nil
            importFiles(at: urls, securityScoped: false)
        }
    }
}

//
//  LectureHomeViewController.swift
//  kisaca
//
//  Top level of the main interface skeleton described in the project brief:
//  Lecture (this screen) → Section → Session (dated notebook), plus the lecture's
//  Materials (its files) in their own row at the top. Shown once
//  `manifest.needsSetup` is false; before that the setup form stands in its place
//  (`AppCoordinator`).
//
//  Its title is the lecture's name, and renameable (the title menu's Rename): it
//  renames through `LectureFileSync.applyLectureName`, so the file name follows. Was the
//  SwiftUI `LectureHomeView` before the UIKit migration (docs/uikit-migration.md).
//

import SwiftUI
import UIKit

final class LectureHomeViewController: UICollectionViewController {
    private let sync: LectureFileSync
    private var document: LectureDocument { sync.document }
    var onOpenSection: (UUID) -> Void = { _ in }
    var onOpenMaterials: () -> Void = {}

    nonisolated private enum ListSection: Hashable { case materials, sections }
    nonisolated private enum Item: Hashable {
        case materials
        case section(UUID)
    }

    private var dataSource: UICollectionViewDiffableDataSource<ListSection, Item>!

    init(sync: LectureFileSync) {
        self.sync = sync
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.renameDelegate = self
        navigationItem.titleMenuProvider = { suggested in UIMenu(children: suggested) }
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                title: "Add Section", image: UIImage(systemName: "plus"),
                primaryAction: UIAction { [weak self] _ in self?.showAddSection() }),
            UIBarButtonItem(
                title: "Semester & Schedule", image: UIImage(systemName: "calendar"),
                primaryAction: UIAction { [weak self] _ in self?.showRoutine() }),
        ]

        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
    }

    /// Reads the manifest, so UIKit calls this again whenever the name, the sections,
    /// their sessions or the materials change.
    override func updateProperties() {
        super.updateProperties()
        navigationItem.title = document.manifest.name

        var snapshot = NSDiffableDataSourceSnapshot<ListSection, Item>()
        snapshot.appendSections([.materials, .sections])
        snapshot.appendItems([.materials], toSection: .materials)
        snapshot.appendItems(
            document.manifest.sections(sortedBySortOrder: true).map { .section($0.id) },
            toSection: .sections)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)

        if document.manifest.sections.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "folder.badge.plus")
            empty.text = "No Sections Yet"
            empty.secondaryText = "Add a section like \"Lectures\" or \"Labs\" to get started."
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    // MARK: - Layout and cells

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            if self?.dataSource?.sectionIdentifier(for: index) == .materials {
                list.footerMode = .supplementary
            }
            return NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let materialsCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.image = UIImage(systemName: "tray.full")
            content.text = "Materials"
            content.secondaryText = materialsSummary
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let sectionCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> {
            [weak self] cell, _, id in
            guard let self, let section = document.manifest.section(withID: id) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.image = UIImage(systemName: section.symbolName)
            content.text = section.name
            content.secondaryText = nextSessionText(in: section)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            cell.contentConfiguration = content

            var accessories: [UICellAccessory] = []
            let count = document.manifest.sessions(in: section).count
            if count > 0 {
                accessories.append(
                    .label(text: "\(count)", options: .init(font: .preferredFont(forTextStyle: .caption1))))
            }
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .materials:
                collectionView.dequeueConfiguredReusableCell(using: materialsCell, for: indexPath, item: item)
            case .section(let id):
                collectionView.dequeueConfiguredReusableCell(using: sectionCell, for: indexPath, item: id)
            }
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { cell, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = "Scripts, slides and exercise sheets, kept inside this lecture's file."
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private var materialsSummary: String {
        let list = document.manifest.materialList
        guard !list.isEmpty else { return "No files yet" }
        let bytes = list.reduce(0) { $0 + $1.byteCount }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(list.count) file\(list.count == 1 ? "" : "s") · \(size)"
    }

    /// "Next: W3 · Thu, 10:00" — the section's next session from now on, if any.
    private func nextSessionText(in section: LectureSection) -> String? {
        let now = Calendar.current.startOfDay(for: Date())
        guard let next = document.manifest.sessions(in: section).first(where: { $0.date >= now })
        else { return nil }
        let time = next.date.formatted(date: .omitted, time: .shortened)
        let isToday = Calendar.current.isDateInToday(next.date)
        // A title without a semester week already carries the date ("Thu · 24.09.2026").
        let titleHasDate = document.manifest.subtitle(for: next) == nil
        let day =
            isToday
            ? "Today, " : titleHasDate ? "" : next.date.formatted(.dateTime.day().month()) + ", "
        return "Next: \(document.manifest.title(for: next)) · \(day)\(time)"
    }

    // MARK: - Selection and actions

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .materials: onOpenMaterials()
        case .section(let id): onOpenSection(id)
        case nil: break
        }
    }

    private func showRoutine() {
        present(UIHostingController(rootView: RoutineSheet(document: document)), animated: true)
    }

    private func showAddSection() {
        let alert = UIAlertController(title: "New Section", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Section name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
                self?.addSection(named: alert?.textFields?.first?.text ?? "")
            })
        present(alert, animated: true)
    }

    private func addSection(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let nextOrder = (document.manifest.sections.map(\.sortOrder).max() ?? -1) + 1
        document.manifest.sections.append(
            LectureSection(name: trimmedName, symbolName: "folder", sortOrder: nextOrder))
    }
}

// MARK: - Renaming from the title

extension LectureHomeViewController: UINavigationItemRenameDelegate {
    func navigationItem(_ navigationItem: UINavigationItem, didEndRenamingWith title: String) {
        sync.applyLectureName(title)
    }

    func navigationItemShouldBeginRenaming(_ navigationItem: UINavigationItem) -> Bool { true }

    func navigationItem(_ navigationItem: UINavigationItem, shouldEndRenamingWith title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

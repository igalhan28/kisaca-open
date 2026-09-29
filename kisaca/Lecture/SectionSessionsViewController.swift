//
//  SectionSessionsViewController.swift
//  kisaca
//
//  Middle level of Lecture → Section → Session. Lists the sessions inside one section
//  and lets the user add one by hand. Three things beyond a plain list:
//
//  - **Whole notebook.** The first row opens every session of the section as one
//    continuous notebook — all of the course's lecture notes, Monday's and Thursday's
//    alike, in order — see `PageRepository.Scope.section`.
//  - **Weeks.** A weekly-named section in a lecture with a semester is grouped by
//    semester week, and the list opens scrolled to the current one.
//  - **Titles** follow the section's naming ("W3 · Mon", "Assignment 3") —
//    `LectureManifest.title(for:)`.
//
//  Sessions for the semester are generated from the lecture's routine
//  (`LectureManifest.generateSessions`); the "+" here is for anything outside it — a
//  make-up lecture, an extra exercise sheet. Was the SwiftUI `SectionSessionsView`
//  before the UIKit migration (docs/uikit-migration.md).
//

import SwiftUI
import UIKit

final class SectionSessionsViewController: UICollectionViewController {
    private let document: LectureDocument
    private let sectionID: UUID
    /// Pushes a notebook (`AppCoordinator`).
    private let onOpenNotebook: (NotebookRoute) -> Void

    nonisolated private enum ListSection: Hashable {
        case wholeNotebook
        /// "week-3", "outside" (sessions outside the semester) or "all" (not grouped).
        case group(id: String, week: Int?)
    }

    nonisolated private enum Item: Hashable {
        case wholeNotebook
        case session(UUID)
    }

    private var dataSource: UICollectionViewDiffableDataSource<ListSection, Item>!
    private var didScrollToCurrentWeek = false

    init(document: LectureDocument, sectionID: UUID, onOpenNotebook: @escaping (NotebookRoute) -> Void) {
        self.document = document
        self.sectionID = sectionID
        self.onOpenNotebook = onOpenNotebook
        super.init(collectionViewLayout: UICollectionViewFlowLayout())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Model

    private var section: LectureSection? { document.manifest.section(withID: sectionID) }

    private var sessions: [LectureSession] { document.manifest.sessions(inSectionWithID: sectionID) }

    private var currentWeek: Int? { document.manifest.semester?.week(of: Date()) }

    /// Sessions grouped for display: by semester week for a weekly-named section in a
    /// lecture with a semester, otherwise one group.
    private func groups(of sessions: [LectureSession]) -> [(section: ListSection, sessions: [LectureSession])] {
        guard section?.naming == .weekly, let semester = document.manifest.semester else {
            return [(.group(id: "all", week: nil), sessions)]
        }
        var byWeek: [Int: [LectureSession]] = [:]
        var outside: [LectureSession] = []
        for session in sessions {
            if let week = semester.week(of: session.date) {
                byWeek[week, default: []].append(session)
            } else {
                outside.append(session)
            }
        }
        var groups = byWeek.keys.sorted().map {
            (section: ListSection.group(id: "week-\($0)", week: $0), sessions: byWeek[$0] ?? [])
        }
        if !outside.isEmpty {
            groups.append((.group(id: "outside", week: nil), outside))
        }
        return groups
    }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Add Session", image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.showAddSession() })

        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
    }

    /// Reads the manifest (and whether pages have notes), so UIKit calls this again
    /// whenever the section's sessions, names or notes change.
    override func updateProperties() {
        super.updateProperties()
        navigationItem.title = section?.name ?? "Section"
        _ = document.pageContentRevision  // "No notes yet", Whole Notebook — page data isn't observed itself

        let sessions = sessions
        var snapshot = NSDiffableDataSourceSnapshot<ListSection, Item>()
        if !PageRepository.notebookSessions(inSection: sectionID, of: document).isEmpty {
            snapshot.appendSections([.wholeNotebook])
            snapshot.appendItems([.wholeNotebook])
        }
        for group in groups(of: sessions) where !group.sessions.isEmpty {
            snapshot.appendSections([group.section])
            snapshot.appendItems(group.sessions.map { .session($0.id) })
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)

        if sessions.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "square.and.pencil")
            empty.text = "No Sessions Yet"
            empty.secondaryText =
                "Add a session, or set the semester and meeting times from the lecture's calendar button to create them all at once."
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollToCurrentWeekOnce()
    }

    /// Not for the first week: the list already starts there, and scrolling would only
    /// push the Whole Notebook row out of sight. The week's header ends up a little below
    /// the navigation bar, not tucked under it.
    ///
    /// Runs after a layout pass, once the collection view holds the snapshot's sections:
    /// asking for a header's position before that throws ("… in section 3 when there are
    /// only 0 sections" — it crashed from `viewIsAppearing`).
    private func scrollToCurrentWeekOnce() {
        guard !didScrollToCurrentWeek, view.window != nil else { return }
        let sections = dataSource.snapshot().sectionIdentifiers
        guard !sections.isEmpty, collectionView.numberOfSections == sections.count else { return }
        didScrollToCurrentWeek = true

        guard let week = currentWeek else { return }
        let weeks = sections.compactMap { section -> Int? in
            if case .group(_, let week) = section { return week }
            return nil
        }
        guard weeks.first != week,
            let index = sections.firstIndex(of: .group(id: "week-\(week)", week: week))
        else { return }

        guard
            let header = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: index))
        else { return }
        let inset = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - inset.top - inset.bottom
        let maxY = max(collectionView.contentSize.height - visibleHeight - inset.top, -inset.top)
        let y = min(header.frame.minY - inset.top - visibleHeight * 0.1, maxY)
        collectionView.contentOffset.y = max(y, -inset.top)
    }

    // MARK: - Layout and cells

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            let section = self?.dataSource?.sectionIdentifier(for: index)
            switch section {
            case .wholeNotebook:
                list.footerMode = .supplementary
            case .group(let id, _) where id != "all":
                list.headerMode = .supplementary
            default:
                break
            }
            return NSCollectionLayoutSection.list(using: list, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let wholeNotebookCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            let included = PageRepository.notebookSessions(inSection: sectionID, of: document)
            let pages = included.reduce(0) { $0 + $1.pageIDs.count }
            var content = UIListContentConfiguration.subtitleCell()
            content.image = UIImage(systemName: "books.vertical")
            content.text = "Whole Notebook"
            content.secondaryText =
                "\(included.count) session\(included.count == 1 ? "" : "s") · \(pages) page\(pages == 1 ? "" : "s") as one book"
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let sessionCell = UICollectionView.CellRegistration<UICollectionViewListCell, UUID> {
            [weak self] cell, _, id in
            guard let self, let session = document.manifest.sessions.first(where: { $0.id == id })
            else { return }
            let isToday = Calendar.current.isDateInToday(session.date)
            let isUpcoming = !isToday && session.date > Date()
            var content = UIListContentConfiguration.subtitleCell()
            content.text = document.manifest.title(for: session)
            content.textProperties.color = isUpcoming ? .secondaryLabel : .label
            content.secondaryText = details(of: session)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            cell.contentConfiguration = content

            var accessories: [UICellAccessory] = []
            if isToday {
                accessories.append(
                    .label(
                        text: "Today",
                        options: .init(
                            tintColor: .tintColor,
                            font: .preferredFont(forTextStyle: .caption1).withWeight(.semibold))))
            }
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .wholeNotebook:
                collectionView.dequeueConfiguredReusableCell(
                    using: wholeNotebookCell, for: indexPath, item: item)
            case .session(let id):
                collectionView.dequeueConfiguredReusableCell(
                    using: sessionCell, for: indexPath, item: id)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, indexPath in
            guard let self, case .group(let id, let week) = dataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            var content = UIListContentConfiguration.header()
            var accessories: [UICellAccessory] = []
            if let week {
                content.text = "Week \(week)"
                if let range = document.manifest.semester?.dateRange(ofWeek: week) {
                    content.secondaryText =
                        "\(range.lowerBound.formatted(.dateTime.day().month())) – \(range.upperBound.formatted(.dateTime.day().month()))"
                    content.prefersSideBySideTextAndSecondaryText = true
                }
                if week == currentWeek {
                    accessories.append(
                        .label(text: "This Week", options: .init(isHidden: false, tintColor: .tintColor)))
                }
            } else if id == "outside" {
                content.text = "Outside the Semester"
            }
            cell.contentConfiguration = content
            cell.accessories = accessories
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { cell, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = "Opens at the latest session. Upcoming sessions join once they start or have notes."
            cell.contentConfiguration = content
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    /// "W3 · 10:00 · 2 pages", or "No notes yet" for a session nothing is written in.
    private func details(of session: LectureSession) -> String {
        let pages = "\(session.pageIDs.count) page\(session.pageIDs.count == 1 ? "" : "s")"
        let hasNotes = session.pageIDs.contains { document.getPageData(for: $0) != nil }
        let parts = [
            document.manifest.subtitle(for: session),
            session.date.formatted(date: .omitted, time: .shortened),
            hasNotes ? pages : "No notes yet",
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Selection and menus

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .wholeNotebook:
            let latest = PageRepository.notebookSessions(inSection: sectionID, of: document).last
            onOpenNotebook(NotebookRoute(scope: .section(sectionID), initialSessionID: latest?.id))
        case .session(let id):
            onOpenNotebook(NotebookRoute(scope: .session(id)))
        case nil:
            break
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, case .session(let id) = dataSource.itemIdentifier(for: indexPaths[0])
        else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: "Delete Session", image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in self?.confirmDelete(sessionID: id) }
            ])
        })
    }

    // MARK: - Actions

    private func confirmDelete(sessionID: UUID) {
        guard let session = document.manifest.sessions.first(where: { $0.id == sessionID }) else { return }
        let title = document.manifest.title(for: session)
        let written = session.pageIDs.filter { document.getPageData(for: $0) != nil }.count
        let notes = written == 0 ? "" : " and its \(written) page\(written == 1 ? "" : "s") of notes"
        let alert = UIAlertController(
            title: "Delete Session?", message: "“\(title)”\(notes) will be permanently deleted.",
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
                self?.document.deleteSession(withID: sessionID)
            })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showAddSession() {
        // Weak: the sheet's own view holds these closures.
        weak var sheet: UIViewController?
        let form = AddSessionSheet(
            date: suggestedNextDate(),
            onCancel: { sheet?.dismiss(animated: true) },
            onAdd: { [weak self] date in
                self?.addSession(on: date)
                sheet?.dismiss(animated: true)
            })
        let controller = UIHostingController(rootView: form)
        controller.sheetPresentationController?.detents = [.medium()]
        sheet = controller
        present(controller, animated: true)
    }

    /// The section's next scheduled meeting from now on, if it has meeting times;
    /// otherwise now.
    private func suggestedNextDate() -> Date {
        guard let section else { return Date() }
        return document.manifest.schedule(for: section)
            .map { $0.nextOccurrence() }
            .min() ?? Date()
    }

    private func addSession(on date: Date) {
        guard let section else { return }
        document.manifest.sessions.append(LectureSession(sectionID: section.id, date: date))
    }
}

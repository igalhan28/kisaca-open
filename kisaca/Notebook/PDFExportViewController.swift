//
//  PDFExportViewController.swift
//  kisaca
//
//  Implements the project brief's "exporting selected / all pages to PDF" requirement.
//  Presented from the notebook's Export button. "All Pages" exports the whole notebook
//  (one session, or a whole section); "Select Pages" shows a thumbnail grid (the saved
//  page thumbnails) with checkmarks, everything checked to start with, so only the
//  pages to leave out need a tap. Replaced the SwiftUI `PDFExportSheet` in the UIKit
//  migration (docs/uikit-migration.md).
//

import ImageIO
import UIKit

final class PDFExportViewController: UIViewController {
    private let document: LectureDocument
    /// "W3 · Mon", or "Lectures · …" for a whole section — the file name's fallback.
    private let notebookTitle: String
    private let coordinator: NotebookCoordinator

    /// The open notebook's pages — one session's, or a whole section's.
    private let pageIDs: [UUID]
    private var selectedIndices: Set<Int>

    private let modeControl = UISegmentedControl(items: ["All Pages", "Select Pages"])
    private let allPagesView = UIView()
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private lazy var exportItem = UIBarButtonItem(
        title: "Export", style: .prominent, target: self, action: #selector(exportTapped))

    private var isSelectingPages: Bool { modeControl.selectedSegmentIndex == 1 }

    init(document: LectureDocument, notebookTitle: String, coordinator: NotebookCoordinator) {
        self.document = document
        self.notebookTitle = notebookTitle
        self.coordinator = coordinator
        pageIDs = coordinator.pageRepository?.pageIDs ?? []
        selectedIndices = Set(pageIDs.indices)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Export PDF"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = exportItem

        modeControl.selectedSegmentIndex = 0
        modeControl.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)

        let icon = UIImageView(
            image: UIImage(
                systemName: "doc.on.doc",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .largeTitle)))
        icon.tintColor = .secondaryLabel
        let count = UILabel()
        count.text = "\(pageIDs.count) page\(pageIDs.count == 1 ? "" : "s") will be exported."
        count.textColor = .secondaryLabel
        count.font = .preferredFont(forTextStyle: .body)
        count.textAlignment = .center
        count.numberOfLines = 0
        let summary = UIStackView(arrangedSubviews: [icon, count])
        summary.axis = .vertical
        summary.alignment = .center
        summary.spacing = 8
        summary.translatesAutoresizingMaskIntoConstraints = false
        allPagesView.addSubview(summary)

        grid.dataSource = self
        grid.delegate = self
        grid.allowsMultipleSelection = true
        grid.register(PageThumbnailCell.self, forCellWithReuseIdentifier: PageThumbnailCell.reuseID)
        grid.isHidden = true

        for subview in [modeControl, allPagesView, grid] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            modeControl.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
            modeControl.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            modeControl.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            allPagesView.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 16),
            allPagesView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            allPagesView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            allPagesView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            summary.centerXAnchor.constraint(equalTo: allPagesView.centerXAnchor),
            summary.centerYAnchor.constraint(equalTo: allPagesView.centerYAnchor),
            summary.leadingAnchor.constraint(greaterThanOrEqualTo: allPagesView.leadingAnchor, constant: 16),
            grid.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        for index in selectedIndices {
            grid.selectItem(at: IndexPath(item: index, section: 0), animated: false, scrollPosition: [])
        }
    }

    private func modeChanged() {
        allPagesView.isHidden = isSelectingPages
        grid.isHidden = !isSelectingPages
        updateExportEnabled()
    }

    private func updateExportEnabled() {
        exportItem.isEnabled = !isSelectingPages || !selectedIndices.isEmpty
    }

    /// Adaptive columns at least 110 pt wide, each cell an A4 page and its number.
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let spacing: CGFloat = 12
            let inset: CGFloat = 16
            let width = environment.container.effectiveContentSize.width - inset * 2
            let columns = max(1, Int((width + spacing) / (110 + spacing)))
            let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let height = cellWidth * PageGeometry.a4Size.height / PageGeometry.a4Size.width + 20

            let item = NSCollectionLayoutItem(
                layoutSize: .init(widthDimension: .absolute(cellWidth), heightDimension: .absolute(height)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
                repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 16
            section.contentInsets = .init(top: inset, leading: inset, bottom: inset, trailing: inset)
            return section
        }
    }

    @objc private func exportTapped() {
        let indices: [Int]? = isSelectingPages ? selectedIndices.sorted() : nil
        coordinator.generatePDF(pageIndices: indices, fileName: exportFileName())
        dismiss(animated: true)
    }

    /// e.g. "Calculus II - Exercise Sessions - W3 · Tue", or "Calculus II - Lectures" for
    /// a whole section.
    private func exportFileName() -> String {
        guard let repository = coordinator.pageRepository else { return "KISACA Notebook" }
        let parts: [String?]
        switch repository.scope {
        case .session(let id):
            let session = document.manifest.sessions.first { $0.id == id }
            parts = [
                document.manifest.name,
                session.flatMap { document.manifest.section(withID: $0.sectionID)?.name },
                session.map { document.manifest.title(for: $0) },
            ]
        case .section(let id):
            parts = [document.manifest.name, document.manifest.section(withID: id)?.name]
        }
        let named = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return named.isEmpty ? notebookTitle : named.joined(separator: " - ")
    }
}

extension PDFExportViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pageIDs.count
    }

    func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PageThumbnailCell.reuseID, for: indexPath) as! PageThumbnailCell
        cell.show(
            pageID: pageIDs[indexPath.item], number: indexPath.item + 1,
            data: document.getThumbnailData(for: pageIDs[indexPath.item]))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectedIndices.insert(indexPath.item)
        updateExportEnabled()
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        selectedIndices.remove(indexPath.item)
        updateExportEnabled()
    }
}

// MARK: - Page thumbnail cell

/// One page: its saved thumbnail on white, a checkmark, and its number underneath.
private final class PageThumbnailCell: UICollectionViewCell {
    static let reuseID = "PageThumbnailCell"

    private let paper = UIImageView()
    private let placeholder = UIImageView(image: UIImage(systemName: "doc.text"))
    private let check = UIImageView()
    private let number = UILabel()
    private var pageID: UUID?
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        paper.backgroundColor = .white
        paper.contentMode = .scaleToFill
        paper.layer.cornerRadius = 6
        paper.layer.cornerCurve = .continuous
        paper.clipsToBounds = true
        placeholder.tintColor = UIColor.gray.withAlphaComponent(0.4)
        placeholder.contentMode = .center
        number.font = .preferredFont(forTextStyle: .caption2)
        number.textColor = .secondaryLabel
        number.textAlignment = .center
        check.backgroundColor = .white
        check.layer.cornerRadius = 11
        check.clipsToBounds = true

        for subview in [paper, placeholder, check, number] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            paper.topAnchor.constraint(equalTo: contentView.topAnchor),
            paper.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            paper.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            paper.heightAnchor.constraint(
                equalTo: paper.widthAnchor,
                multiplier: PageGeometry.a4Size.height / PageGeometry.a4Size.width),
            placeholder.centerXAnchor.constraint(equalTo: paper.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: paper.centerYAnchor),
            check.topAnchor.constraint(equalTo: paper.topAnchor, constant: 4),
            check.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -4),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22),
            number.topAnchor.constraint(equalTo: paper.bottomAnchor, constant: 4),
            number.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        ])
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        paper.layer.borderColor =
            (isSelected ? UIColor.tintColor : UIColor.gray.withAlphaComponent(0.3)).cgColor
        paper.layer.borderWidth = isSelected ? 3 : 1
        // "circle" has one layer, so it takes the first palette colour: gray, not the
        // white that fills the checkmark.
        check.image = UIImage(
            systemName: isSelected ? "checkmark.circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(
                paletteColors: isSelected ? [.white, .tintColor] : [.gray]))
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        paper.image = nil
    }

    /// Decodes the thumbnail off the main thread, downsampled to the cell: a saved
    /// thumbnail can be far larger than 110 pt (see `PageRepository.loadThumbnail`).
    func show(pageID: UUID, number: Int, data: Data?) {
        self.pageID = pageID
        self.number.text = "\(number)"
        accessibilityLabel = "Page \(number)"
        placeholder.isHidden = data != nil
        guard let data else { return }
        let maxPixels = max(bounds.width, 110) * 3 * PageGeometry.a4Size.height
            / PageGeometry.a4Size.width
        loadTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                Self.downsampled(data, maxPixels: maxPixels)
            }.value
            guard !Task.isCancelled, let self, self.pageID == pageID else { return }
            paper.image = image
            placeholder.isHidden = image != nil
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
}

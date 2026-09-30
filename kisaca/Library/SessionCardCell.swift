//
//  SessionCardCell.swift
//  kisaca
//
//  The home screen's cards. A session card is the top of the session's first page (grid
//  + ink thumbnail) above a strip saying which lecture and section it belongs to and when
//  it is; a placeholder card stands in for a lecture with nothing to show yet. Were the
//  SwiftUI `SessionCard` / `PlaceholderCard` before the UIKit migration
//  (docs/uikit-migration.md).
//

import UIKit

enum SessionCardMetrics {
    static let width: CGFloat = 240
    static let paperHeight: CGFloat = 150
    static let height: CGFloat = paperHeight + 56
    static let cornerRadius: CGFloat = 16
}

// MARK: - Session card

final class SessionCardCell: UICollectionViewCell {
    static let reuseID = "SessionCardCell"

    private let paper = GridPaperView()
    private let thumbnail = UIImageView()
    private let badge = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let badgeIcon = UIImageView()
    private let todayChip = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let strip = UIView()
    private let bookIcon = UIImageView(image: UIImage(systemName: "book.closed.fill"))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    /// What the thumbnail being loaded is for — a reused cell checks it still shows it.
    private var thumbnailKey: String?
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = SessionCardMetrics.cornerRadius
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        contentView.layer.borderWidth = 0.5
        contentView.backgroundColor = .secondarySystemBackground

        thumbnail.contentMode = .scaleToFill
        paper.addSubview(thumbnail)
        paper.clipsToBounds = true

        badge.layer.cornerRadius = 16
        badge.clipsToBounds = true
        badgeIcon.contentMode = .center
        badgeIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        badge.contentView.addSubview(badgeIcon)

        todayChip.text = "Today"
        todayChip.font = .preferredFont(forTextStyle: .caption1).withWeight(.bold)
        todayChip.textColor = .white
        todayChip.textAlignment = .center
        todayChip.layer.cornerRadius = 11
        todayChip.clipsToBounds = true

        bookIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabel
        strip.backgroundColor = .secondarySystemBackground

        for view in [paper, badge, todayChip, spinner, strip] as [UIView] { contentView.addSubview(view) }
        for view in [bookIcon, titleLabel, detailLabel] as [UIView] { strip.addSubview(view) }

        isAccessibilityElement = true
        accessibilityTraits = .button
        updateBorder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: SessionCardCell, _) in
            self.updateBorder()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateBorder() {
        contentView.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        paper.frame = CGRect(x: 0, y: 0, width: width, height: SessionCardMetrics.paperHeight)
        let scale = width / PageGeometry.a4Size.width
        thumbnail.frame = CGRect(x: 0, y: 0, width: width, height: PageGeometry.a4Size.height * scale)
        badge.frame = CGRect(x: width - 40, y: 8, width: 32, height: 32)
        badgeIcon.frame = badge.bounds
        let chipWidth = todayChip.intrinsicContentSize.width + 16
        todayChip.frame = CGRect(x: 10, y: 10, width: chipWidth, height: 22)
        spinner.center = paper.center

        strip.frame = CGRect(
            x: 0, y: SessionCardMetrics.paperHeight, width: width,
            height: contentView.bounds.height - SessionCardMetrics.paperHeight)
        let iconSize = bookIcon.intrinsicContentSize
        let lineHeight = titleLabel.font.lineHeight
        bookIcon.frame = CGRect(
            x: 12, y: 10 + (lineHeight - iconSize.height) / 2, width: iconSize.width,
            height: iconSize.height)
        titleLabel.frame = CGRect(
            x: bookIcon.frame.maxX + 6, y: 10, width: width - bookIcon.frame.maxX - 6 - 12,
            height: lineHeight)
        detailLabel.frame = CGRect(
            x: 12, y: titleLabel.frame.maxY + 3, width: width - 24,
            height: detailLabel.font.lineHeight)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        thumbnailKey = nil
        thumbnail.image = nil
    }

    /// - Parameters:
    ///   - showsLecture: shelves that mix lectures name the lecture; a lecture's own doesn't.
    ///   - emphasizesDay: upcoming sessions say the day in words ("Today", "Tomorrow").
    func configure(with item: SessionItem, showsLecture: Bool, emphasizesDay: Bool, isOpening: Bool) {
        let tint = LectureColor.color(for: item.lecture.name)
        let isToday = Calendar.current.isDateInToday(item.session.date)

        paper.gridSpacingMM = item.session.gridSpacingMM
        badgeIcon.image = UIImage(systemName: item.sectionSymbol)
        badgeIcon.tintColor = tint
        todayChip.backgroundColor = tint
        todayChip.isHidden = !(emphasizesDay && isToday)
        if isOpening { spinner.startAnimating() } else { spinner.stopAnimating() }

        bookIcon.tintColor = tint
        titleLabel.text = showsLecture ? "\(item.lecture.name) · \(item.sectionName)" : item.sectionName
        detailLabel.text = item.title + " · " + Self.dateText(for: item, emphasizesDay: emphasizesDay)
        accessibilityLabel = [titleLabel.text, detailLabel.text].compactMap { $0 }.joined(separator: ", ")

        loadThumbnail(
            lectureURL: item.lecture.url, pageID: item.session.pageIDs.first,
            modified: item.lecture.modified)
        setNeedsLayout()
    }

    private static func dateText(for item: SessionItem, emphasizesDay: Bool) -> String {
        let date = item.session.date
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        // "Thu · 24.09.2026" already says the day.
        if item.titleHasDate { return time }
        if emphasizesDay {
            if calendar.isDateInToday(date) { return time }
            if calendar.isDateInTomorrow(date) { return "Tomorrow, \(time)" }
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + ", " + time
    }

    /// The saved ink thumbnail of the session's first page, read off the main thread and
    /// cached per lecture file version.
    private func loadThumbnail(lectureURL: URL, pageID: UUID?, modified: Date?) {
        let key = "\(lectureURL.path)|\(pageID?.uuidString ?? "-")|\(modified?.timeIntervalSince1970 ?? 0)"
        guard key != thumbnailKey else { return }
        loadTask?.cancel()
        thumbnailKey = key
        thumbnail.image = nil
        guard let pageID else { return }
        if let cached = ThumbnailCache.shared.object(forKey: key as NSString) {
            thumbnail.image = cached
            return
        }
        let url = lectureURL
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("\(pageID.uuidString).ink.png")
        loadTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let data, let image = UIImage(data: data) else { return }
            ThumbnailCache.shared.setObject(image, forKey: key as NSString)
            guard let self, !Task.isCancelled, thumbnailKey == key else { return }
            thumbnail.image = image
        }
    }
}

// MARK: - Placeholder card

/// A lecture with nothing to show yet: not set up, still downloading, or no sessions.
final class PlaceholderCardCell: UICollectionViewCell {
    static let reuseID = "PlaceholderCardCell"

    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = SessionCardMetrics.cornerRadius
        contentView.layer.cornerCurve = .continuous
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title1)
        icon.contentMode = .center
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, spinner, message])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with entry: LectureEntry, isOpening: Bool) {
        let busy = isOpening || entry.state == .loading
        icon.isHidden = busy
        spinner.isHidden = !busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        icon.image = UIImage(systemName: Self.symbol(for: entry))
        icon.tintColor = LectureColor.color(for: entry.name)
        message.text = Self.message(for: entry)
        accessibilityLabel = "\(entry.name), \(message.text ?? "")"
    }

    private static func symbol(for entry: LectureEntry) -> String {
        switch entry.state {
        case .downloading: "icloud.and.arrow.down"
        case .unreadable: "exclamationmark.triangle"
        default: entry.manifest?.needsSetup == true ? "wand.and.stars" : "calendar.badge.plus"
        }
    }

    private static func message(for entry: LectureEntry) -> String {
        switch entry.state {
        case .loading: "Loading…"
        case .downloading: "Downloading from iCloud…"
        case .unreadable: "This file couldn't be read."
        case .ready:
            entry.manifest?.needsSetup == true
                ? "Finish setting up this lecture"
                : "No sessions yet — set the semester and meeting times"
        }
    }
}

// MARK: - Paper

/// White paper with the notebook's grid, as the top of a page looks in the notebook —
/// always light, like the notebook's. Lines every `gridSpacingMM`, scaled to the card.
final class GridPaperView: UIView {
    var gridSpacingMM: Double = LectureSession.defaultGridSpacingMM {
        didSet { if gridSpacingMM != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor.white.setFill()
        context.fill(bounds)
        let scale = bounds.width / PageGeometry.a4Size.width
        let step = gridSpacingMM * 72 / 25.4 * scale
        guard step > 2 else { return }
        let path = UIBezierPath()
        var x = step
        while x < bounds.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bounds.height))
            x += step
        }
        var y = step
        while y < bounds.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
            y += step
        }
        path.lineWidth = 0.5
        PageGeometry.gridColor.setStroke()
        path.stroke()
    }
}

// MARK: - Shared

@MainActor
enum ThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()
}

/// A lecture's colour on the home screen, picked from its name so it stays the same on
/// every launch and every device (Swift's `hashValue` is randomized per launch).
enum LectureColor {
    private static let palette: [UIColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPink, .systemPurple, .systemTeal,
        .systemIndigo, .systemRed, .systemYellow, .systemBrown,
    ]

    static func color(for name: String) -> UIColor {
        var hash: UInt32 = 5381
        // Composed first: file names can come back decomposed ("c" + cedilla).
        for byte in name.precomposedStringWithCanonicalMapping.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

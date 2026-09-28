//
//  SessionCard.swift
//  kisaca
//
//  A session on the home screen: the top of its first page (grid + ink thumbnail),
//  and a strip below saying which lecture and section it belongs to and when it is.
//

import SwiftUI
import UIKit

enum SessionCardMetrics {
    static let width: CGFloat = 240
    static let paperHeight: CGFloat = 150
}

struct SessionCard: View {
    let item: SessionItem
    /// Home-screen shelves that mix lectures name the lecture; a lecture's own shelf doesn't.
    let showsLecture: Bool
    /// Upcoming sessions say the day in words ("Today", "Tomorrow").
    let emphasizesDay: Bool
    let isOpening: Bool

    private var tint: Color { LectureColor.color(for: item.lecture.name) }
    private var isToday: Bool { Calendar.current.isDateInToday(item.session.date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PagePreview(
                lectureURL: item.lecture.url, pageID: item.session.pageIDs.first,
                modified: item.lecture.modified, gridSpacingMM: item.session.gridSpacingMM
            )
            .frame(width: SessionCardMetrics.width, height: SessionCardMetrics.paperHeight)
            .overlay(alignment: .topTrailing) {
                Image(systemName: item.sectionSymbol)
                    .font(.subheadline)
                    .foregroundStyle(tint)
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
                    .padding(8)
            }
            .overlay(alignment: .topLeading) {
                if emphasizesDay, isToday {
                    Text("Today")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint, in: Capsule())
                        .padding(10)
                }
            }
            .overlay {
                if isOpening { ProgressView().controlSize(.large) }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed.fill")
                        .foregroundStyle(tint)
                    Text(showsLecture ? "\(item.lecture.name) · \(item.sectionName)" : item.sectionName)
                        .lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                Text(item.title + " · " + dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: SessionCardMetrics.width, alignment: .leading)
            .background(.background.secondary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var dateText: String {
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
}

/// A lecture with nothing to show yet: not set up, still downloading, or no sessions.
struct PlaceholderCard: View {
    let entry: LectureEntry
    let isOpening: Bool

    var body: some View {
        VStack(spacing: 10) {
            if isOpening || entry.state == .loading {
                ProgressView()
            } else {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(LectureColor.color(for: entry.name))
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(
            width: SessionCardMetrics.width,
            height: SessionCardMetrics.paperHeight + 56)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var symbol: String {
        switch entry.state {
        case .downloading: "icloud.and.arrow.down"
        case .unreadable: "exclamationmark.triangle"
        default: entry.manifest?.needsSetup == true ? "wand.and.stars" : "calendar.badge.plus"
        }
    }

    private var message: String {
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

// MARK: - Page preview

/// The top of a page as it looks in the notebook: the grid, and the saved ink thumbnail
/// over it. Paper is always light, like the notebook's.
private struct PagePreview: View {
    let lectureURL: URL
    let pageID: UUID?
    let modified: Date?
    let gridSpacingMM: Double

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / PageGeometry.a4Size.width
            ZStack(alignment: .top) {
                Color.white
                Canvas { context, size in
                    let step = gridSpacingMM * 72 / 25.4 * scale
                    guard step > 2 else { return }
                    var path = Path()
                    var x = step
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        x += step
                    }
                    var y = step
                    while y < size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        y += step
                    }
                    context.stroke(path, with: .color(Color(PageGeometry.gridColor)), lineWidth: 0.5)
                }
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(
                            width: geometry.size.width,
                            height: PageGeometry.a4Size.height * scale)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
        .task(id: cacheKey) { await load() }
    }

    private var cacheKey: String {
        "\(lectureURL.path)|\(pageID?.uuidString ?? "-")|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    private func load() async {
        guard let pageID else {
            image = nil
            return
        }
        if let cached = ThumbnailCache.shared.object(forKey: cacheKey as NSString) {
            image = cached
            return
        }
        let url = lectureURL
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent("\(pageID.uuidString).ink.png")
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard let data, let loaded = UIImage(data: data) else { return }
        ThumbnailCache.shared.setObject(loaded, forKey: cacheKey as NSString)
        image = loaded
    }
}

@MainActor
private enum ThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()
}

// MARK: - Lecture colour

/// A lecture's colour on the home screen, picked from its name so it stays the same
/// on every launch and every device (Swift's `hashValue` is randomized per launch).
enum LectureColor {
    private static let palette: [Color] = [
        .blue, .orange, .green, .pink, .purple, .teal, .indigo, .red, .yellow, .brown,
    ]

    static func color(for name: String) -> Color {
        var hash: UInt32 = 5381
        // Composed first: file names can come back decomposed ("c" + cedilla).
        for byte in name.precomposedStringWithCanonicalMapping.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

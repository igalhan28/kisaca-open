//
//  PageRepository.swift
//  kisaca
//
//  Read/write access to one notebook's pages, backed by `LectureDocument`. A notebook
//  is either one session, or a whole section read as one continuous book (every
//  Monday and Thursday lecture in order) — see `Scope`. This is
//  pure data plumbing — no view/gesture/lifecycle concerns — used by
//  `NotebookScrollViewController` to load a page's markup on demand and persist it
//  back. It has no opinion about how many pages are alive at once; that's the
//  collection view's job (cell reuse), not this class's.
//

import Foundation
import ImageIO
import PaperKit
import UIKit

@MainActor
final class PageRepository {

    nonisolated enum Scope: Hashable {
        /// One dated session.
        case session(UUID)
        /// A section's sessions back to back, as one notebook.
        case section(UUID)
    }

    private let document: LectureDocument
    let scope: Scope

    /// The sessions this notebook shows, in order — fixed when the notebook opens.
    ///
    /// Fixed because the scroll view addresses pages by index, and a session list that
    /// grew in the middle while open (a future session gaining its first ink, midnight
    /// passing) would shift every index after it without the scroll view knowing.
    /// Pages *within* these sessions do come and go — `insertPage(after:)` and
    /// `removePage(at:)` — but only through the scroll view, which re-indexes with them.
    let sessionIDs: [UUID]

    init(document: LectureDocument, scope: Scope, now: Date = Date()) {
        self.document = document
        self.scope = scope
        switch scope {
        case .session(let id):
            sessionIDs = [id]
        case .section(let id):
            sessionIDs = Self.notebookSessions(inSection: id, of: document, now: now).map(\.id)
        }
    }

    /// The sessions a section's whole-notebook view shows: everything up to today,
    /// plus any later session that already has ink. The semester's future, still-empty
    /// meetings are left out — thirty blank pages at the end of the book are noise.
    static func notebookSessions(
        inSection sectionID: UUID, of document: LectureDocument, now: Date = Date()
    ) -> [LectureSession] {
        let endOfToday = Semester.endOfDay(now)
        return document.manifest.sessions(inSectionWithID: sectionID).filter { session in
            session.date < endOfToday
                || session.pageIDs.contains { document.getPageData(for: $0) != nil }
        }
    }

    private var sessions: [LectureSession] {
        sessionIDs.compactMap { id in document.manifest.sessions.first { $0.id == id } }
    }

    /// Ordered page IDs for this notebook. Reads straight from the document's
    /// manifest each time rather than caching a local copy — the manifest is the
    /// single source of truth, and this is cheap (an array of UUIDs).
    var pageIDs: [UUID] {
        sessions.flatMap(\.pageIDs)
    }

    var pageCount: Int { pageIDs.count }

    /// The session that owns the page at `index` — what the toolbar names while
    /// scrolling through a whole-section notebook.
    func session(forPageAt index: Int) -> LectureSession? {
        var remaining = index
        for session in sessions {
            if remaining < session.pageIDs.count { return session }
            remaining -= session.pageIDs.count
        }
        return sessions.last
    }

    /// Grid square side, in page points, for the page at `index`.
    func gridSpacing(forPageAt index: Int) -> CGFloat {
        PageGeometry.gridSpacing(
            millimeters: session(forPageAt: index)?.gridSpacingMM
                ?? LectureSession.defaultGridSpacingMM)
    }

    /// "W3 · Mon" for the session owning the page at `index`.
    func sessionTitle(forPageAt index: Int) -> String? {
        session(forPageAt: index).map { document.manifest.title(for: $0) }
    }

    /// Index of the first page of `sessionID` in this notebook.
    func firstPageIndex(of sessionID: UUID) -> Int? {
        var index = 0
        for session in sessions {
            if session.id == sessionID { return index }
            index += session.pageIDs.count
        }
        return nil
    }

    // MARK: - Page list mutation

    /// Where the page at `index` lives: its session's position in the manifest, and its
    /// position within that session's `pageIDs`.
    private func location(ofPageAt index: Int) -> (session: Int, offset: Int)? {
        guard index >= 0 else { return nil }
        var remaining = index
        for id in sessionIDs {
            guard let s = document.manifest.sessions.firstIndex(where: { $0.id == id }) else {
                continue
            }
            let count = document.manifest.sessions[s].pageIDs.count
            if remaining < count { return (s, remaining) }
            remaining -= count
        }
        return nil
    }

    /// Inserts a new blank page right after the page at `index`, in that page's session,
    /// and returns the new page's index. Only ever called for a deliberate user action
    /// (the "add page" button), never speculatively.
    @discardableResult
    func insertPage(after index: Int) -> Int? {
        guard let (s, offset) = location(ofPageAt: index) else { return nil }
        document.manifest.sessions[s].pageIDs.insert(UUID(), at: offset + 1)
        return index + 1
    }

    /// A session always keeps at least one page, so the last page of a session stays.
    func canRemovePage(at index: Int) -> Bool {
        guard let (s, _) = location(ofPageAt: index) else { return false }
        return document.manifest.sessions[s].pageIDs.count > 1
    }

    /// Removes the page at `index` and its ink. Returns whether it did.
    @discardableResult
    func removePage(at index: Int) -> Bool {
        guard canRemovePage(at: index), let (s, offset) = location(ofPageAt: index) else {
            return false
        }
        document.manifest.sessions[s].pageIDs.remove(at: offset)
        document.pruneOrphanedPageData()
        return true
    }

    // MARK: - Markup I/O

    /// Loads markup for a page index. Returns blank markup if none exists yet
    /// (brand-new page) or if decoding fails (corrupt data — fails safe rather than
    /// crashing or losing the rest of the session).
    func loadMarkup(forPageAt index: Int) -> PaperMarkup {
        guard index >= 0, index < pageIDs.count else {
            return PaperMarkup(bounds: PageGeometry.a4Bounds)
        }
        let id = pageIDs[index]
        // A save still encoding holds newer ink than the document does.
        if let pending = pendingSaves[id] { return pending.markup }
        guard let data = document.getPageData(for: id) else {
            return PaperMarkup(bounds: PageGeometry.a4Bounds)
        }
        do {
            return try PaperMarkup(dataRepresentation: data)
        } catch {
            print("[PageRepository] Failed to decode page \(id): \(error)")
            return PaperMarkup(bounds: PageGeometry.a4Bounds)
        }
    }

    /// Markup handed to `saveMarkup` whose bytes aren't in the document yet, by page.
    ///
    /// Encoding is async (`dataRepresentation()`), and the notebook reloads a page as
    /// soon as it gets a live canvas again — which a quick zoom out and back in does
    /// within that window. Reading the document then returned the ink from *before*
    /// the save, the canvas showed it, and the next save wrote it back over the newer
    /// ink: work lost whenever the user didn't pause between zooms. Loads read this
    /// first, so they always see the newest ink.
    private var pendingSaves: [UUID: (generation: Int, markup: PaperMarkup)] = [:]
    private var saveGeneration = 0

    /// Persists markup for a page. Takes effect for `loadMarkup` immediately; the bytes
    /// reach the document once PaperKit's async encode finishes.
    ///
    /// Addressed by page ID, not index: the encode finishes some time after it was
    /// asked for, and a page added or deleted in between shifts every index after it.
    /// The page may itself be gone by then (deleted mid-encode), in which case the
    /// bytes are dropped instead of resurrecting its data. An encode overtaken by a
    /// newer save of the same page is dropped too, so an older, slower encode can
    /// never land on top of newer ink.
    func saveMarkup(_ markup: PaperMarkup, forPageID id: UUID) {
        saveGeneration += 1
        let generation = saveGeneration
        pendingSaves[id] = (generation, markup)
        Task {
            defer {
                if pendingSaves[id]?.generation == generation { pendingSaves[id] = nil }
            }
            do {
                let data = try await markup.dataRepresentation()
                guard pendingSaves[id]?.generation == generation, pageIDs.contains(id) else {
                    return
                }
                document.setPageData(data, for: id)
            } catch {
                print("[PageRepository] Failed to encode page \(id): \(error)")
            }
        }
    }

    // MARK: - Thumbnails

    /// PNG, not JPEG: a thumbnail is ink only, on transparency, and is laid *over* the
    /// tile's live grid — so the grid stays sharp at every zoom instead of being
    /// baked into the image at one resolution.
    func saveThumbnail(_ image: UIImage, for pageID: UUID) {
        // A thumbnail render can finish after its page was deleted.
        guard pageIDs.contains(pageID), let data = image.pngData() else { return }
        document.setThumbnailData(data, for: pageID)
    }

    /// Renders a thumbnail for a page that has ink but no (current-format) thumbnail
    /// — every page of a document saved before thumbnails became ink-only PNGs. Saves
    /// it and returns it, or `nil` for a page with no ink or undecodable markup.
    func regenerateThumbnail(forPageAt index: Int) async -> UIImage? {
        guard index >= 0, index < pageIDs.count else { return nil }
        let id = pageIDs[index]
        guard document.getPageData(for: id) != nil || pendingSaves[id] != nil,
            let image = await PageRenderer.renderInk(
                loadMarkup(forPageAt: index), scale: Self.thumbnailScale, whiteBackground: false)
        else { return nil }
        saveThumbnail(image, for: id)
        return image
    }

    /// Pixels per page point for regenerated thumbnails — about what a snapshot of a
    /// fit-to-width page on an iPad comes out at. Also the cap on live snapshots — see
    /// `PageCanvasController.renderSnapshot()`.
    static let thumbnailScale: CGFloat = 2.5

    /// Downsampled while decoding, never decoded at full size: documents saved before
    /// snapshots were capped can hold thumbnails taken at deep zoom, which decode to
    /// around a gigabyte each.
    func loadThumbnail(for pageID: UUID) -> UIImage? {
        guard let data = document.getThumbnailData(for: pageID),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let maxPixels = PageGeometry.a4Size.height * Self.thumbnailScale
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

//
//  LectureLibrary.swift
//  kisaca
//
//  Where the lectures live, and the list of them the home screen shows. See
//  docs/library.md.
//
//  Lectures are kept in the app's own folders, never out in Files:
//  - iCloud (`iCloud Drive/KISACA`, the app's ubiquity container) when the user is
//    signed in to iCloud with iCloud Drive on — synced to their other devices;
//  - `On My iPad/KISACA` (the app's Documents folder) otherwise, and for any lecture
//    created before iCloud was available. Settings can move those to iCloud.
//  Both are listed together. Files the user keeps elsewhere are brought in with
//  Import, which copies them here: a file outside the app's own folders is only
//  reachable through a security-scoped URL, which is what broke opening materials
//  and renaming on real devices (docs/naming.md).
//

import Foundation
import Observation
import UIKit

/// One `.kisaca` package in the library, with the parts of its manifest the home
/// screen needs. The manifest is read without opening the document.
nonisolated struct LectureEntry: Identifiable, Sendable {
    enum State: Sendable {
        case loading
        /// Only in iCloud so far — being downloaded to this device.
        case downloading
        case ready
        case unreadable
    }

    let url: URL
    var modified: Date?
    var isInICloud: Bool
    var state: State
    var manifest: LectureManifest?

    var id: String { url.standardizedFileURL.path }
    var name: String {
        let fromFile = DocumentNaming.lectureName(fromFileURL: url)
        return fromFile.isEmpty ? (manifest?.name ?? "Lecture") : fromFile
    }
}

/// One session as the home screen shows it: which lecture it's in, and how it's named.
struct SessionItem: Identifiable {
    let lecture: LectureEntry
    let session: LectureSession
    let title: String
    /// The title is a date ("Thu · 24.09.2026") rather than a week or a number.
    let titleHasDate: Bool
    let sectionName: String
    let sectionSymbol: String

    var id: String { lecture.id + "#" + session.id.uuidString }
}

/// A lecture that is open: its `UIDocument`, kept for as long as one of its screens is
/// on the navigation stack.
final class OpenLecture: Identifiable {
    let id = UUID()
    let file: LectureFile
    var document: LectureDocument { file.model }

    init(file: LectureFile) { self.file = file }
}

enum LibraryError: LocalizedError {
    case unavailable
    case couldNotOpen(String)
    case couldNotCreate

    var errorDescription: String? {
        switch self {
        case .unavailable: "The lecture folder isn't available yet."
        case .couldNotOpen(let name): "“\(name)” couldn't be opened."
        case .couldNotCreate: "The new lecture couldn't be created."
        }
    }
}

@MainActor
@Observable
final class LectureLibrary {
    nonisolated static let fileExtension = "kisaca"

    /// `iCloud Drive/KISACA` on this device, or `nil` when iCloud Drive isn't available
    /// to the app (signed out, iCloud Drive off, or turned off for KISACA).
    private(set) var iCloudFolder: URL?
    /// `On My iPad/KISACA`. Always there.
    let localFolder: URL = URL.documentsDirectory

    private(set) var entries: [LectureEntry] = []
    private(set) var hasStarted = false
    /// Every place lectures can be has been looked at once — until then an empty list
    /// doesn't mean there are none.
    private(set) var hasLoaded = false

    /// Lectures currently open, by `OpenLecture.id` (what navigation routes carry).
    private(set) var openLectures: [UUID: OpenLecture] = [:]

    /// Where new and imported lectures go.
    var primaryFolder: URL { iCloudFolder ?? localFolder }
    var usesICloud: Bool { iCloudFolder != nil }
    var localLectureCount: Int { entries.filter { !$0.isInICloud }.count }

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var iCloudFound: [URL: (modified: Date?, downloaded: Bool)] = [:]
    @ObservationIgnored private var localFound: [URL: Date?] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var reading: Set<URL> = []

    // MARK: - Start

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.connectICloud() }
                }
            })
        // Local lectures show straight away; looking up iCloud can take a while (or
        // wait on an account prompt).
        refresh()
        await connectICloud()
    }

    /// Looks up the ubiquity container (which can block, so off the main actor) and
    /// starts watching it — or stops, if iCloud went away.
    private func connectICloud() async {
        let folder = await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
            else { return nil }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: documents, withIntermediateDirectories: true)
            return documents
        }.value

        guard folder != iCloudFolder else {
            if folder == nil { hasLoaded = true }
            return
        }
        stopQuery()
        iCloudFolder = folder
        iCloudFound = [:]
        if folder != nil {
            startQuery()  // `hasLoaded` once it has gathered
        } else {
            hasLoaded = true
        }
        rebuildEntries()
    }

    // MARK: - Finding files

    /// iCloud: `NSMetadataQuery` is the only way to learn about files that exist in
    /// iCloud but haven't been downloaded to this device yet, and it reports changes
    /// from other devices as they arrive.
    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.\(Self.fileExtension)")
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.queryChanged() }
                })
        }
        self.query = query
        query.start()
    }

    private func stopQuery() {
        query?.stop()
        query = nil
    }

    private func queryChanged() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var found: [URL: (modified: Date?, downloaded: Bool)] = [:]
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                !url.path.contains("/.Trash/")
            else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            found[url.standardizedFileURL] = (
                item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                status == NSMetadataUbiquitousItemDownloadingStatusCurrent
            )
        }
        iCloudFound = found
        hasLoaded = true
        rebuildEntries()
    }

    /// `On My iPad/KISACA` — a plain folder; rescanned whenever the app comes back to
    /// the foreground or the library itself changes something.
    private func scanLocal() {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: localFolder, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        var found: [URL: Date?] = [:]
        for url in urls where url.pathExtension == Self.fileExtension {
            found[url.standardizedFileURL] =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        localFound = found
    }

    /// Rescans what can't report its own changes. Call when the app becomes active.
    func refresh() {
        scanLocal()
        rebuildEntries()
    }

    /// Merges what was found with what's already known, keeping each manifest that is
    /// still current and (re)reading the rest.
    private func rebuildEntries() {
        let known = Dictionary(entries.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [LectureEntry] = []

        func add(_ url: URL, modified: Date?, inICloud: Bool, downloaded: Bool) {
            var entry = known[url] ?? LectureEntry(
                url: url, modified: nil, isInICloud: inICloud, state: .loading, manifest: nil)
            let changed = entry.modified != modified || entry.manifest == nil
            entry.modified = modified
            entry.isInICloud = inICloud
            if !downloaded {
                entry.state = .downloading
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            } else if changed {
                if entry.manifest == nil { entry.state = .loading }
                readManifest(of: url)
            }
            result.append(entry)
        }

        for (url, info) in iCloudFound {
            add(url, modified: info.modified, inICloud: true, downloaded: info.downloaded)
        }
        for (url, modified) in localFound {
            add(url, modified: modified, inICloud: false, downloaded: true)
        }
        entries = result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func readManifest(of url: URL) {
        guard !reading.contains(url) else { return }
        reading.insert(url)
        Task {
            let manifest = await Task.detached(priority: .utility) {
                Self.readManifest(at: url)
            }.value
            reading.remove(url)
            guard let i = entries.firstIndex(where: { $0.url == url }) else { return }
            entries[i].manifest = manifest ?? entries[i].manifest
            entries[i].state = manifest == nil ? .unreadable : .ready
        }
    }

    /// Reads just `manifest.json`, coordinated so it never sees a half-written save.
    nonisolated static func readManifest(at url: URL) -> LectureManifest? {
        var manifest: LectureManifest?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: .withoutChanges, error: &error
        ) { readURL in
            guard let data = try? Data(contentsOf: readURL.appendingPathComponent("manifest.json"))
            else { return }
            manifest = try? JSONDecoder().decode(LectureManifest.self, from: data)
        }
        return manifest
    }

    // MARK: - Sessions for the home screen

    private func items(in entry: LectureEntry) -> [SessionItem] {
        guard let manifest = entry.manifest, !manifest.needsSetup else { return [] }
        return manifest.sessions.map { session in
            let section = manifest.section(withID: session.sectionID)
            return SessionItem(
                lecture: entry, session: session, title: manifest.title(for: session),
                titleHasDate: manifest.subtitle(for: session) == nil,
                sectionName: section?.name ?? "", sectionSymbol: section?.symbolName ?? "book")
        }
    }

    /// Sessions from the start of today on, soonest first.
    func upcomingSessions(limit: Int = 16, now: Date = Date()) -> [SessionItem] {
        let start = Calendar.current.startOfDay(for: now)
        return entries.flatMap(items(in:))
            .filter { $0.session.date >= start }
            .sorted { $0.session.date < $1.session.date }
            .prefix(limit).map { $0 }
    }

    /// Sessions before today, most recent first.
    func recentSessions(limit: Int = 16, now: Date = Date()) -> [SessionItem] {
        let start = Calendar.current.startOfDay(for: now)
        return entries.flatMap(items(in:))
            .filter { $0.session.date < start }
            .sorted { $0.session.date > $1.session.date }
            .prefix(limit).map { $0 }
    }

    /// All of one lecture's sessions, in date order.
    func sessions(of entry: LectureEntry) -> [SessionItem] {
        items(in: entry).sorted { $0.session.date < $1.session.date }
    }

    // MARK: - Opening and closing

    func openLecture(withID id: UUID) -> OpenLecture? { openLectures[id] }

    /// Opens the lecture at `url`, or returns it if it's already open.
    func open(_ url: URL) async throws -> OpenLecture {
        if let open = openLectures.values.first(where: {
            $0.file.fileURL.standardizedFileURL == url.standardizedFileURL
        }) {
            return open
        }
        let file = LectureFile(url: url)
        guard await file.open() else {
            throw LibraryError.couldNotOpen(DocumentNaming.lectureName(fromFileURL: url))
        }
        let lecture = OpenLecture(file: file)
        openLectures[lecture.id] = lecture
        return lecture
    }

    /// Saves and closes every open lecture — the home screen is showing again.
    func closeAll() async {
        let open = Array(openLectures.values)
        openLectures = [:]
        for lecture in open {
            await lecture.file.close()
        }
        refresh()
    }

    // MARK: - Creating, importing, deleting

    /// Creates an empty lecture (it opens in setup) and returns it, open.
    func createLecture() async throws -> OpenLecture {
        let url = Self.availableURL(in: primaryFolder, baseName: "Untitled")
        let file = LectureFile(url: url)
        guard await file.save(to: url, for: .forCreating) else { throw LibraryError.couldNotCreate }
        let lecture = OpenLecture(file: file)
        openLectures[lecture.id] = lecture
        refresh()
        return lecture
    }

    /// Copies `.kisaca` files picked in Files (or opened from another app) into the
    /// library. Returns the new URLs; the originals are left where they were.
    func importLectures(from urls: [URL]) async -> (imported: [URL], failed: [String]) {
        let folder = primaryFolder
        var imported: [URL] = []
        var failed: [String] = []
        for url in urls {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.copy(url, into: folder) }
            }.value
            switch result {
            case .success(let copy): imported.append(copy)
            case .failure(let error):
                print("kisaca: import of \(url.lastPathComponent) failed: \(error)")
                failed.append(url.deletingPathExtension().lastPathComponent)
            }
        }
        refresh()
        return (imported, failed)
    }

    /// Whether `url` is one of the library's own files (vs. one opened from elsewhere).
    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.deletingLastPathComponent().path
        return [iCloudFolder, localFolder].compactMap { $0?.standardizedFileURL.path }
            .contains(path)
    }

    private nonisolated static func copy(_ source: URL, into folder: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let destination = availableURL(
            in: folder, baseName: source.deletingPathExtension().lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        // Coordinated reading also downloads a file that's only in the cloud (iCloud
        // Drive, or another app's file provider) before the copy starts.
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source, options: [], writingItemAt: destination,
            options: .forReplacing, error: &coordinationError
        ) { readURL, writeURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: writeURL)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }

    /// Deletes a lecture (in iCloud: from every device).
    func delete(_ entry: LectureEntry) async throws {
        let url = entry.url
        try await Task.detached(priority: .userInitiated) {
            var coordinationError: NSError?
            var deleteError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: url, options: .forDeleting, error: &coordinationError
            ) { writeURL in
                do {
                    try FileManager.default.removeItem(at: writeURL)
                } catch {
                    deleteError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let deleteError { throw deleteError }
        }.value
        entries.removeAll { $0.url == url }
        refresh()
    }

    /// Moves the lectures kept only on this device into iCloud.
    func moveLocalLecturesToICloud() async -> [String] {
        guard let iCloudFolder else { return [] }
        var failed: [String] = []
        for entry in entries where !entry.isInICloud {
            let source = entry.url
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let destination = Self.availableURL(
                        in: iCloudFolder, baseName: source.deletingPathExtension().lastPathComponent)
                    try FileManager.default.setUbiquitous(true, itemAt: source, destinationURL: destination)
                }
            }.value
            if case .failure(let error) = result {
                print("kisaca: moving \(source.lastPathComponent) to iCloud failed: \(error)")
                failed.append(entry.name)
            }
        }
        refresh()
        return failed
    }

    /// `<baseName>.kisaca` in `folder`, with " 2", " 3"… added until the name is free.
    nonisolated static func availableURL(in folder: URL, baseName: String) -> URL {
        let base = baseName.isEmpty ? "Untitled" : baseName
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)")
                .appendingPathExtension(fileExtension)
            n += 1
        }
        return candidate
    }
}

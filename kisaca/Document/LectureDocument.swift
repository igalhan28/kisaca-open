//
//  LectureDocument.swift
//  kisaca
//
//  The in-memory model of one `.kisaca` lecture package. `LectureFile` (the app's
//  `UIDocument`) owns one of these and hands it the package's `FileWrapper` on every
//  load and asks it for a new one on every save. See docs/document-format.md
//  ("Document format" and "Autosave design") for why page data is not @Published and
//  how autosave is triggered, and docs/library.md for how files are found and opened.
//

import Combine
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// `@MainActor` like everything else in the app: `@Published` state must be mutated on
// the main actor, and UIKit calls `UIDocument.load(fromContents:)` and
// `contents(forType:)` — the only two entry points from the file system — on the main
// queue. See docs/actor-isolation.md for the history (it used to be a
// `ReferenceFileDocument` behind `DocumentGroup`).
@MainActor
final class LectureDocument: ObservableObject {

    /// Immutable, Sendable copy handed to `fileWrapper(snapshot:existingFile:)`.
    /// Mirrors exactly the state written to disk. Explicitly `nonisolated` for the
    /// same reason as the `LectureModels.swift` types it's built from — see that
    /// file's header comment.
    nonisolated struct Snapshot: Sendable {
        var manifest: LectureManifest
        var pageData: [UUID: Data]
        var thumbnailData: [UUID: Data]
        /// Only materials added since the document was opened. Everything else is
        /// carried over from the package already on disk — see `fileWrapper`.
        var newMaterialData: [UUID: Data]
    }

    // MARK: - Published state

    /// Every mutation — including in-place ones like `manifest.sessions.append(…)` — marks
    /// the document dirty. `objectWillChange` alone does NOT: see `markDirty()`.
    @Published var manifest: LectureManifest {
        didSet { markDirty() }
    }

    // MARK: - Live UIDocument (see LectureFile.swift)

    /// The `LectureFile` this model belongs to. It is the authority on where the file
    /// currently lives and on whether it has unsaved changes.
    weak var host: UIDocument?

    /// The file's current location. Follows the document when it is renamed or moved
    /// while open.
    var liveFileURL: URL? { host?.fileURL }

    /// Tells the system this document has unsaved changes, so it schedules an autosave.
    ///
    /// `objectWillChange.send()` does not do this for a `ReferenceFileDocument`: SwiftUI
    /// learns about edits from the undo manager, and this app's manifest edits never
    /// register undo actions — so before this existed, a lecture set up and renamed
    /// without drawing anything was never written to disk (verified in the simulator:
    /// no `snapshot` call, `manifest.json` left at "New Lecture" / `needsSetup`).
    func markDirty() {
        guard !isLoading else { return }
        host?.updateChangeCount(.done)
    }

    // MARK: - Page data (deliberately NOT @Published — see docs/document-format.md → "Autosave design")

    /// PaperKit markup bytes, keyed by page UUID. Mutate only through
    /// `setPageData(_:for:)` so the document is marked dirty when it matters.
    private(set) var pageData: [UUID: Data]
    /// Cached thumbnails (ink-only PNGs), keyed by page UUID.
    ///
    /// Stored as `<uuid>.ink.png`. Older documents have `<uuid>.thumb.jpg` files: JPEGs
    /// with the paper's grid baked in, which would show a second, blurry grid under
    /// the live one. Those are deliberately not read — pages without a thumbnail get
    /// one regenerated from their markup — and they drop out of the package on the
    /// next save, since `fileWrapper` rebuilds `Thumbnails/` from this dictionary.
    private(set) var thumbnailData: [UUID: Data]

    private static let thumbnailSuffix = ".ink.png"

    // MARK: - Material files (see docs/document-format.md → "Materials")
    //
    // Unlike page ink, material files are NOT read into memory when the document
    // opens: a lecture's scripts and slides can be hundreds of MB. The manifest lists
    // them; the bytes stay in the package's `Materials/` folder and are carried from
    // one save to the next by reusing the existing file wrappers, never re-read.

    /// Bytes of materials added since the document was opened, until they are part
    /// of the package on disk. Kept for the whole session: a snapshot may be taken
    /// before or after any given save, and it must always be able to write them.
    private var newMaterialData: [UUID: Data] = [:]

    /// `Materials/` as it was when the document was opened — a fallback for reading
    /// a file and for a save that gets no `existingFile` to carry files over from.
    private var openedMaterialWrappers: [String: FileWrapper] = [:]

    // MARK: - Init (new document)

    init() {
        manifest = LectureManifest()
        pageData = [:]
        thumbnailData = [:]
    }

    /// True while `load(from:)` replaces the contents, so it doesn't count as an edit.
    private var isLoading = false

    // MARK: - Reading a package from disk

    /// Replaces the whole state with the package in `root`. Called by `LectureFile` on
    /// open, and again whenever the file changes underneath (an iCloud update from
    /// another device, a conflict resolved) — so it must fully reset, not merge.
    func load(from root: FileWrapper) throws {
        guard root.isDirectory else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard
            let manifestWrapper = root.fileWrappers?["manifest.json"],
            let manifestData = manifestWrapper.regularFileContents
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var decodedManifest = try JSONDecoder().decode(LectureManifest.self, from: manifestData)

        var pages: [UUID: Data] = [:]
        if let pagesDir = root.fileWrappers?["Pages"]?.fileWrappers {
            for (filename, wrapper) in pagesDir {
                guard filename.hasSuffix(".paperkit"),
                    let content = wrapper.regularFileContents,
                    let id = UUID(uuidString: String(filename.dropLast(".paperkit".count)))
                else { continue }
                pages[id] = content
            }
        }

        // Sessions from before the grid size was stored read as the old 5 mm grid, so
        // their ink keeps lining up. One with no ink yet (a timetable meeting generated
        // ahead of time) has nothing to line up: it gets the new grid, like any new
        // session. Pinned in the manifest, so it stays put once written on.
        for i in decodedManifest.sessions.indices
        where decodedManifest.sessions[i].storedGridSpacingMM == nil {
            if !decodedManifest.sessions[i].pageIDs.contains(where: { pages[$0] != nil }) {
                decodedManifest.sessions[i].storedGridSpacingMM = LectureSession.defaultGridSpacingMM
            }
        }

        var thumbs: [UUID: Data] = [:]
        if let thumbsDir = root.fileWrappers?["Thumbnails"]?.fileWrappers {
            for (filename, wrapper) in thumbsDir {
                guard filename.hasSuffix(Self.thumbnailSuffix),
                    let content = wrapper.regularFileContents,
                    let id = UUID(
                        uuidString: String(filename.dropLast(Self.thumbnailSuffix.count)))
                else { continue }
                thumbs[id] = content
            }
        }

        isLoading = true
        defer { isLoading = false }
        objectWillChange.send()
        pageData = pages
        thumbnailData = thumbs
        openedMaterialWrappers = root.fileWrappers?["Materials"]?.fileWrappers ?? [:]
        manifest = decodedManifest
    }

    // MARK: - Snapshot (captures current live state — see Snapshot's own doc comment)

    func snapshot() -> Snapshot {
        Snapshot(
            manifest: manifest, pageData: pageData, thumbnailData: thumbnailData,
            newMaterialData: newMaterialData)
    }

    // MARK: - Write

    /// The package to write for `snapshot`. `existingFile` is the package as it is on
    /// disk (as last loaded or saved): unchanged files are reused from it, so a save
    /// only rewrites what changed.
    func fileWrapper(snapshot: Snapshot, existingFile: FileWrapper?) throws -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])

        let manifestData = try JSONEncoder().encode(snapshot.manifest)
        root.addRegularFile(withContents: manifestData, preferredFilename: "manifest.json")

        let existingPages = existingFile?.fileWrappers?["Pages"]?.fileWrappers ?? [:]
        let pagesDir = FileWrapper(directoryWithFileWrappers: [:])
        pagesDir.preferredFilename = "Pages"
        for (id, data) in snapshot.pageData {
            let filename = "\(id.uuidString).paperkit"
            if let existing = existingPages[filename], existing.regularFileContents == data {
                // Unchanged — reuse the existing wrapper so the OS doesn't rewrite this file.
                pagesDir.addFileWrapper(existing)
            } else {
                pagesDir.addRegularFile(withContents: data, preferredFilename: filename)
            }
        }
        root.addFileWrapper(pagesDir)

        let existingThumbs =
            existingFile?.fileWrappers?["Thumbnails"]?.fileWrappers ?? [:]
        let thumbsDir = FileWrapper(directoryWithFileWrappers: [:])
        thumbsDir.preferredFilename = "Thumbnails"
        for (id, data) in snapshot.thumbnailData {
            let filename = "\(id.uuidString)\(Self.thumbnailSuffix)"
            if let existing = existingThumbs[filename], existing.regularFileContents == data {
                thumbsDir.addFileWrapper(existing)
            } else {
                thumbsDir.addRegularFile(withContents: data, preferredFilename: filename)
            }
        }
        root.addFileWrapper(thumbsDir)

        // Materials: new ones from memory; the rest reused from the package on disk, so
        // an unchanged 50 MB script is neither read nor rewritten by a save. A material
        // removed from the manifest is simply not carried over.
        let existingMaterials =
            existingFile?.fileWrappers?["Materials"]?.fileWrappers ?? [:]
        let materialsDir = FileWrapper(directoryWithFileWrappers: [:])
        materialsDir.preferredFilename = "Materials"
        for material in snapshot.manifest.materialList {
            let filename = material.storedFileName
            if let data = snapshot.newMaterialData[material.id] {
                materialsDir.addRegularFile(withContents: data, preferredFilename: filename)
            } else if let existing = existingMaterials[filename]
                ?? openedMaterialWrappers[filename]
            {
                materialsDir.addFileWrapper(existing)
            } else {
                print("kisaca: material \(filename) has no bytes to save — dropped")
            }
        }
        root.addFileWrapper(materialsDir)

        return root
    }

    // MARK: - Page data mutation API (used by Notebook/PageRepository)

    /// Writes page markup bytes and marks the document dirty so UIDocument autosaves it.
    /// This is the ONE place a markup edit becomes visible to the save system — see
    /// docs/document-format.md → "Autosave design".
    func setPageData(_ data: Data, for id: UUID) {
        objectWillChange.send()
        pageData[id] = data
        markDirty()
    }

    func getPageData(for id: UUID) -> Data? {
        pageData[id]
    }

    func setThumbnailData(_ data: Data, for id: UUID) {
        objectWillChange.send()
        thumbnailData[id] = data
        markDirty()
    }

    func getThumbnailData(for id: UUID) -> Data? {
        thumbnailData[id]
    }

    // MARK: - Materials

    /// Adds a file to the lecture's materials and returns its entry.
    @discardableResult
    func addMaterial(
        data: Data, fileName: String, contentType: UTType?, week: Int? = nil
    ) -> CourseMaterial {
        let material = CourseMaterial(
            title: (fileName as NSString).deletingPathExtension,
            originalFileName: fileName,
            contentTypeIdentifier: contentType?.identifier,
            byteCount: data.count, week: week)
        newMaterialData[material.id] = data
        manifest.materials = manifest.materialList + [material]  // marks the document dirty
        return material
    }

    func removeMaterial(withID id: UUID) {
        newMaterialData.removeValue(forKey: id)
        manifest.materials = manifest.materialList.filter { $0.id != id }
    }

    /// Files a material under a week, or under the whole lecture (`nil`).
    func setMaterialWeek(_ week: Int?, forMaterialWithID id: UUID) {
        guard var list = manifest.materials, let i = list.firstIndex(where: { $0.id == id })
        else { return }
        list[i].week = week
        manifest.materials = list
    }

    func renameMaterial(withID id: UUID, to title: String) {
        guard var list = manifest.materials, let i = list.firstIndex(where: { $0.id == id })
        else { return }
        list[i].title = title
        manifest.materials = list
    }

    /// The file's bytes: from memory if it was added this session, otherwise read
    /// from the package — the live file first (it follows renames and moves), then
    /// the wrapper captured at open. The disk read happens off the main actor.
    func materialData(for material: CourseMaterial) async -> Data? {
        if let data = newMaterialData[material.id] { return data }
        if let fileURL = liveFileURL?
            .appendingPathComponent("Materials", isDirectory: true)
            .appendingPathComponent(material.storedFileName),
            let data = await Task.detached(operation: {
                try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            }).value
        {
            return data
        }
        return openedMaterialWrappers[material.storedFileName]?.regularFileContents
    }

    /// Deletes a session together with the ink of all its pages.
    func deleteSession(withID id: UUID) {
        manifest.removeSession(withID: id)
        pruneOrphanedPageData()
    }

    /// Removes page/thumbnail bytes that no longer belong to any session. Call after
    /// deleting a session, section or page (`deleteSession`, `PageRepository.removePage`).
    func pruneOrphanedPageData() {
        let keep = manifest.allPageIDs
        let orphanedPages = Set(pageData.keys).subtracting(keep)
        let orphanedThumbs = Set(thumbnailData.keys).subtracting(keep)
        guard !orphanedPages.isEmpty || !orphanedThumbs.isEmpty else { return }
        objectWillChange.send()
        for id in orphanedPages { pageData.removeValue(forKey: id) }
        for id in orphanedThumbs { thumbnailData.removeValue(forKey: id) }
        markDirty()
    }
}

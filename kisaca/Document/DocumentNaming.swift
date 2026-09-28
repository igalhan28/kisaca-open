//
//  DocumentNaming.swift
//  kisaca
//
//  Keeps the two things that used to be able to disagree — the *lecture name*
//  (`LectureManifest.name`, typed in `LectureSetupView`) and the *file name* of the
//  `.kisaca` package on disk (renameable from the document browser, or from the
//  title menu) — as one value. See docs/naming.md.
//
//  Direction of truth:
//  · file name → lecture name  on open / whenever the document's URL changes
//    (someone renamed it in Files or the document browser; the file is what they see).
//  · lecture name → file name  on an explicit in-app rename (setup "Create", or the
//    title menu's Rename). Renaming the package is coordinated via NSFileCoordinator
//    so the open UIDocument behind DocumentGroup follows the move instead of losing
//    track of its own file.
//
//  `nonisolated` for the same reason as `LectureModels.swift`: the project default is
//  MainActor isolation, and none of this needs the main actor — the rename in
//  particular is deliberately called from a detached task so a slow coordinated file
//  move never blocks drawing.
//

import Foundation

nonisolated enum DocumentNaming {

    /// Extension of the document package. Kept here as a fallback only — the real
    /// extension always comes from the document's own URL.
    static let packageExtension = "kisaca"

    // MARK: - Reading a name off a URL

    /// The lecture name implied by a document's file name ("Anal II.kisaca" → "Anal II").
    static func lectureName(fromFileURL url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// True for the names the document browser makes up on its own ("Untitled",
    /// "Untitled 2", …). Those are not worth pre-filling the setup form with.
    static func isPlaceholderFileName(_ baseName: String) -> Bool {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased().hasPrefix("untitled")
    }

    // MARK: - Turning a name into a legal file name

    /// Sanitizes a user-typed lecture name into something safe to put on disk.
    /// Returns "" if nothing usable is left, in which case the caller should leave the
    /// existing file name alone rather than rename it to garbage.
    static func fileBaseName(forLectureName name: String) -> String {
        var result = name.components(separatedBy: .controlCharacters).joined()
        // "/" is a path separator and ":" is still shown as "/" in Finder — both would
        // either fail the move or produce a confusing name.
        for bad in ["/", ":"] {
            result = result.replacingOccurrences(of: bad, with: "-")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the document.
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leave room for the extension and a " 2" disambiguator under the 255-byte
        // per-component limit; 200 characters is comfortably inside it.
        if result.count > 200 { result = String(result.prefix(200)) }
        return result
    }

    // MARK: - Renaming the package on disk

    /// Renames the document package at `url` so its base name is `lectureName`.
    /// Returns the URL it ended up at (unchanged if no rename was needed or possible).
    ///
    /// Safe to call while the document is open: the move goes through
    /// `NSFileCoordinator` with `item(at:willMoveTo:)`/`item(at:didMoveTo:)`, which is
    /// what tells the open `UIDocument` (a registered file presenter) to follow its
    /// file to the new URL.
    @discardableResult
    static func renameDocument(at url: URL, toMatch lectureName: String) throws -> URL {
        let base = fileBaseName(forLectureName: lectureName)
        guard !base.isEmpty else { return url }
        guard base != url.deletingPathExtension().lastPathComponent else { return url }

        // Documents opened from outside the app's own container are security-scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension.isEmpty ? packageExtension : url.pathExtension
        let target = availableURL(in: directory, baseName: base, extension: ext, ignoring: url)

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        var movedTo = url

        coordinator.coordinate(
            writingItemAt: url, options: .forMoving,
            writingItemAt: target, options: .forReplacing,
            error: &coordinationError
        ) { fromURL, toURL in
            coordinator.item(at: fromURL, willMoveTo: toURL)
            do {
                try FileManager.default.moveItem(at: fromURL, to: toURL)
                coordinator.item(at: fromURL, didMoveTo: toURL)
                movedTo = toURL
            } catch {
                moveError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let moveError { throw moveError }
        return movedTo
    }

    /// `<baseName>.<ext>` in `directory`, with " 2", " 3"… appended until it's free.
    /// `ignoring` is the document's own current URL — a case-only rename
    /// ("anal ii" → "Anal II") must not be treated as a collision with itself on a
    /// case-insensitive file system.
    private static func availableURL(
        in directory: URL, baseName: String, extension ext: String, ignoring: URL
    ) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path),
            candidate.path.compare(ignoring.path, options: .caseInsensitive) != .orderedSame
        {
            candidate =
                directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }
}

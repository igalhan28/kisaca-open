//
//  LectureFile.swift
//  kisaca
//
//  The `UIDocument` behind one open lecture. It does the file-system side — coordinated
//  reads and writes, autosave, following the file when it moves, reloading when iCloud
//  brings a newer version — and keeps a `LectureDocument` as the in-memory model the
//  views observe. See docs/library.md.
//
//  Replaces DocumentGroup (and the UIKit document browser that came with it): the app
//  now finds its own files (`LectureLibrary`), so it opens them itself.
//

import UIKit

// UIKit doesn't isolate `UIDocument` to the main actor, so its overrides here are
// nonisolated. Every `LectureFile` is created on the main actor (by LectureLibrary),
// and each entry point below hops there before touching the MainActor-only model —
// which is what makes the `@unchecked Sendable` true.
final class LectureFile: UIDocument, @unchecked Sendable {
    let model: LectureDocument

    /// The package as it is on disk, as last loaded or saved — passed to the model as
    /// `existingFile` so a save reuses every file that didn't change. Only touched on
    /// the main thread.
    nonisolated(unsafe) private var diskWrapper: FileWrapper?

    /// Why the last load failed, if it did — `open()` only reports a `Bool`. Main thread only.
    nonisolated(unsafe) private(set) var loadError: (any Error)?

    @MainActor
    init(url: URL) {
        model = LectureDocument()
        super.init(fileURL: url)
        model.host = self
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let contents = contents as? FileWrapper else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Handed over, not shared: UIKit doesn't touch it again after this call.
        nonisolated(unsafe) let wrapper = contents
        try Self.onMain {
            do {
                try model.load(from: wrapper)
            } catch {
                loadError = error
                throw error
            }
            loadError = nil
            diskWrapper = wrapper
        }
    }

    override func contents(forType typeName: String) throws -> Any {
        try Self.onMain {
            // A newer build saved this file while it was open here (an iCloud update
            // this build couldn't load): writing the old in-memory state back would
            // overwrite that newer work.
            if let error = loadError as? LectureFormatError { throw error }
            let wrapper = try model.fileWrapper(snapshot: model.snapshot(), existingFile: diskWrapper)
            diskWrapper = wrapper
            return wrapper
        }
    }

    override func handleError(_ error: any Error, userInteractionPermitted: Bool) {
        print("kisaca: \(fileURL.lastPathComponent): \(error)")
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
    }

    /// Runs `body` on the main actor: in place when already on the main thread (where
    /// UIKit normally calls these), otherwise by a real hop — not an unchecked
    /// `assumeIsolated`, see docs/actor-isolation.md.
    private nonisolated static func onMain<T>(_ body: @MainActor () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(body)
        }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }
}

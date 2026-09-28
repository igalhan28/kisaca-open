//
//  DocumentConflictResolver.swift
//  kisaca
//
//  Asks which version to keep when an opened lecture has iCloud conflict versions.
//
//  A conflict appears when the same lecture is changed on two devices (or saved twice
//  on one) before iCloud has synced them. The document is then `.inConflict`. Under
//  the old DocumentGroup it never finished opening — the browser stayed on top and
//  the app looked frozen (seen on the iPad with "Anal II" and "TheoC 2"). Nothing
//  handles conflicts for us, so `LectureScreen` calls this on its `LectureFile`
//  when it appears and on every state change.
//
//  The versions can hold very different data — one "TheoC 2" conflict had 44 sessions
//  against 3 in the current version — so nothing is picked automatically: the user
//  sees each version's device, date and size, and chooses. The others are discarded.
//

import Foundation
import UIKit

@MainActor
enum DocumentConflictResolver {

    /// Documents a picker is currently showing for, so a second state change doesn't
    /// stack another one on top.
    private static var presenting: Set<URL> = []

    /// Shows the picker if `document` is in conflict. Safe to call repeatedly.
    static func resolveIfNeeded(_ document: UIDocument) {
        let url = document.fileURL.standardizedFileURL
        guard document.documentState.contains(.inConflict), !presenting.contains(url) else {
            return
        }
        presenting.insert(url)

        Task {
            let versions = await Task.detached { Version.all(of: url) }.value
            guard versions.count > 1 else {
                presenting.remove(url)
                return
            }
            present(versions, of: document, at: url)
        }
    }

    // MARK: - Versions

    /// One candidate: the current file or one of its conflict versions.
    nonisolated struct Version: Sendable {
        /// `nil` for the current version.
        let conflictURL: URL?
        let device: String
        let date: Date?
        let sessionCount: Int?

        static func all(of url: URL) -> [Version] {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let current = NSFileVersion.currentVersionOfItem(at: url)
            var result = [
                Version(
                    conflictURL: nil,
                    device: current?.localizedNameOfSavingComputer ?? "This device",
                    date: current?.modificationDate,
                    sessionCount: sessionCount(inPackageAt: url))
            ]
            for conflict in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                result.append(
                    Version(
                        conflictURL: conflict.url,
                        device: conflict.localizedNameOfSavingComputer ?? "Another device",
                        date: conflict.modificationDate,
                        sessionCount: sessionCount(inPackageAt: conflict.url)))
            }
            return result.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }

        private static func sessionCount(inPackageAt url: URL) -> Int? {
            guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sessions = manifest["sessions"] as? [Any]
            else { return nil }
            return sessions.count
        }

        var title: String {
            var parts = [device]
            if let date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
            if let sessionCount { parts.append("\(sessionCount) sessions") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Picker

    private static func present(_ versions: [Version], of document: UIDocument, at url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let alert = UIAlertController(
            title: "Which version do you want to keep?",
            message: "“\(name)” was changed on more than one device. The other versions will be deleted.",
            preferredStyle: .alert)
        for version in versions {
            alert.addAction(
                UIAlertAction(title: version.title, style: .default) { _ in
                    keep(version, of: document, at: url)
                })
        }
        // From the topmost controller in the key window: a sheet may be up.
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var presenter = window?.rootViewController else {
            presenting.remove(url)
            return
        }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(alert, animated: true)
    }

    private static func keep(_ version: Version, of document: UIDocument, at url: URL) {
        Task {
            let result = await Task.detached { Result { try resolve(url, keeping: version.conflictURL) } }.value
            presenting.remove(url)
            if case .failure(let error) = result {
                print("kisaca: could not resolve conflict for \(url.lastPathComponent): \(error)")
                return
            }
            // If the document ended up closed while in conflict, open it again now that
            // there's one version (under DocumentGroup it stayed closed until relaunch).
            if document.documentState.contains(.closed) {
                let opened = await document.open()
                print("kisaca: reopened \(url.lastPathComponent) after resolving conflict: \(opened) state=\(document.documentState.rawValue)")
            }
        }
    }

    /// Makes `conflictURL`'s version (or the current one, for `nil`) the file's
    /// content and removes every other version. Coordinated, so the open `UIDocument`
    /// is told the file changed and reloads it.
    private nonisolated static func resolve(_ url: URL, keeping conflictURL: URL?) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var resolveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { writeURL in
            do {
                let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: writeURL) ?? []
                if let conflictURL, let chosen = conflicts.first(where: { $0.url == conflictURL }) {
                    try chosen.replaceItem(at: writeURL, options: [])
                }
                for conflict in conflicts { conflict.isResolved = true }
                try NSFileVersion.removeOtherVersionsOfItem(at: writeURL)
            } catch {
                resolveError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let resolveError { throw resolveError }
    }
}

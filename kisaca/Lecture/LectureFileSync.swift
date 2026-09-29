//
//  LectureFileSync.swift
//  kisaca
//
//  The single funnel for an open lecture's name, keeping `manifest.name` and the file
//  name equal in both directions (docs/naming.md), plus the other things that follow the
//  file while the lecture is on screen: iCloud conflicts (`DocumentConflictResolver`)
//  and saving when the app goes to the background.
//
//  One per open lecture, kept by `AppCoordinator` while the lecture's screens are on
//  the navigation stack — shared by the setup form and the lecture's home screen, so
//  it outlives the switch from one to the other. Was `LectureScreen` (a SwiftUI view)
//  before the UIKit migration (docs/uikit-migration.md).
//

import UIKit

final class LectureFileSync {
    let document: LectureDocument
    let file: LectureFile

    /// The name a rename is currently moving the file to; non-nil only while that
    /// coordinated move is in flight. It de-duplicates a rename committed twice, and
    /// keeps `reconcileNameWithFile()` from reading a half-moved file and reverting the
    /// name.
    private var renamingTo: String?
    private var observers: [NSObjectProtocol] = []

    /// Where the file is right now — `UIDocument` follows it when it moves.
    private var currentFileURL: URL? { document.liveFileURL }

    init(document: LectureDocument, file: LectureFile) {
        self.document = document
        self.file = file

        let center = NotificationCenter.default
        // Files (or another device, through iCloud) can move the file behind our back;
        // `UIDocument` posts a state change when it does. A conflict can also arrive
        // while the lecture is open — iCloud syncing a change made elsewhere.
        observers.append(
            center.addObserver(
                forName: UIDocument.stateChangedNotification, object: file, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.fileStateChanged() }
            })
        observers.append(
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main)
            { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileNameWithFile() }
            })
        observers.append(
            center.addObserver(
                forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.file.autosave(completionHandler: nil) }
            })

        fileStateChanged()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func fileStateChanged() {
        reconcileNameWithFile()
        DocumentConflictResolver.resolveIfNeeded(file)
    }

    // MARK: - Name sync
    //
    // The file name is the truth: it is what Files and the home screen show. The
    // lecture name (`manifest.name`) must always equal it.

    /// file name → lecture name. Runs on open, when the app becomes active again, and
    /// whenever the file moves (someone renamed it in Files, or on another device — the
    /// name they can see wins). Deliberately skipped while `needsSetup` is true, so a
    /// placeholder "Untitled" never becomes the lecture's real name.
    func reconcileNameWithFile() {
        guard renamingTo == nil, !document.manifest.needsSetup, let url = currentFileURL
        else { return }
        // While a move is in progress `fileURL` may still hold the old location.
        if document.host?.documentState.contains(.editingDisabled) == true { return }
        let base = DocumentNaming.lectureName(fromFileURL: url)
        guard !base.isEmpty, base != document.manifest.name else { return }
        document.manifest.name = base
    }

    /// lecture name → file name. The only way the name is set from inside the app —
    /// used by both the setup form's "Create" and the title menu's "Rename".
    ///
    /// The lecture name is set to what was typed straight away (so the title never
    /// lags), then to the name the file *actually* ended up with: the system may have
    /// changed it (illegal characters replaced, " 2" added on a collision). If the
    /// rename fails, the name falls back to the file's real name instead of staying
    /// different from it.
    func applyLectureName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, renamingTo != trimmed else { return }

        document.manifest.name = trimmed
        guard let url = currentFileURL else { return }

        let base = DocumentNaming.fileBaseName(forLectureName: trimmed)
        guard !base.isEmpty, base != DocumentNaming.lectureName(fromFileURL: url) else {
            return
        }

        renamingTo = trimmed
        Task {
            // Write everything (including the new name) to disk before the file moves.
            _ = await document.host?.autosave()

            // Detached: a coordinated move can block on iCloud, and this runs from a
            // button tap on the main actor. The file is in the app's own folder, so a
            // plain coordinated move is allowed (it wasn't out in Files — docs/naming.md).
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DocumentNaming.renameDocument(at: url, toMatch: trimmed) }
            }.value
            var finalURL: URL?
            switch result {
            case .success(let movedURL) where movedURL != url:
                finalURL = movedURL
            case .success:
                break
            case .failure(let error):
                print("kisaca: could not rename document to \"\(trimmed)\": \(error)")
            }

            renamingTo = nil
            if let finalURL {
                let actual = DocumentNaming.lectureName(fromFileURL: finalURL)
                if !actual.isEmpty, document.manifest.name != actual {
                    document.manifest.name = actual
                }
            } else {
                reconcileNameWithFile()
            }
        }
    }

    /// What the setup form's name field starts out with: the file's name if it already
    /// has a real one, otherwise empty (never "Untitled").
    var suggestedSetupName: String {
        let manifestName = document.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manifestName.isEmpty, manifestName != LectureManifest().name {
            return manifestName
        }
        guard let url = currentFileURL else { return "" }
        let base = DocumentNaming.lectureName(fromFileURL: url)
        return DocumentNaming.isPlaceholderFileName(base) ? "" : base
    }
}

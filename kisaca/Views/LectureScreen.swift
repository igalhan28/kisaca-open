//
//  LectureScreen.swift
//  kisaca
//
//  Root of one open lecture, pushed onto the app's navigation stack from the home
//  screen (LibraryHomeView). Routes between the one-time setup flow and the
//  Lecture → Section → Session navigation, and is the single funnel for the
//  lecture's name, keeping `manifest.name` and the file name equal in both
//  directions. See DocumentNaming.swift and docs/naming.md.
//

import SwiftUI
import UIKit

struct LectureScreen: View {
    @ObservedObject var document: LectureDocument
    let file: LectureFile

    @Environment(\.scenePhase) private var scenePhase

    /// The name a rename is currently moving the file to; non-nil only while that
    /// coordinated move is in flight. It de-duplicates the commit SwiftUI's renameable
    /// title fires twice per rename, and keeps `reconcileNameWithFile()` from reading a
    /// half-moved file and reverting the name.
    @State private var renamingTo: String?

    /// Where the file is right now — `UIDocument` follows it when it moves.
    private var currentFileURL: URL? { document.liveFileURL }

    var body: some View {
        Group {
            if document.manifest.needsSetup {
                LectureSetupView(
                    document: document,
                    initialName: suggestedSetupName,
                    onCommitName: applyLectureName
                )
            } else {
                LectureHomeView(
                    document: document,
                    onRename: applyLectureName
                )
            }
        }
        .onAppear {
            reconcileNameWithFile()
            DocumentConflictResolver.resolveIfNeeded(file)
        }
        // Files (or another device, through iCloud) can move the file behind our back;
        // `UIDocument` posts a state change when it does. A conflict can also arrive
        // while the lecture is open — iCloud syncing a change made elsewhere.
        .onReceive(
            NotificationCenter.default.publisher(for: UIDocument.stateChangedNotification, object: file)
        ) { _ in
            reconcileNameWithFile()
            DocumentConflictResolver.resolveIfNeeded(file)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reconcileNameWithFile() }
            if phase == .background { file.autosave(completionHandler: nil) }
        }
    }

    // MARK: - Name sync
    //
    // The file name is the truth: it is what Files and the home screen show. The
    // lecture name (`manifest.name`) must always equal it.

    /// file name → lecture name. Runs on open, when the app becomes active again, and
    /// whenever the file moves (someone renamed it in Files, or on another device — the
    /// name they can see wins). Deliberately skipped while `needsSetup` is true, so
    /// a placeholder "Untitled" never becomes the lecture's real name.
    private func reconcileNameWithFile() {
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
    private func applyLectureName(_ newName: String) {
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
    private var suggestedSetupName: String {
        let manifestName = document.manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manifestName.isEmpty, manifestName != LectureManifest().name {
            return manifestName
        }
        guard let url = currentFileURL else { return "" }
        let base = DocumentNaming.lectureName(fromFileURL: url)
        return DocumentNaming.isPlaceholderFileName(base) ? "" : base
    }
}

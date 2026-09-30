//
//  AppPreferences.swift
//  kisaca
//
//  Device-local preferences: how *this* iPad lays things out, as opposed to what a
//  lecture contains. They live in `UserDefaults`, not in the `.kisaca` document, so they
//  survive closing and reopening the app, are not synced to other devices through the
//  lecture file, and apply to every lecture alike.
//
//  Every key and default is defined here once. The Settings form
//  (`LibrarySettingsView`, SwiftUI) binds to them with `@AppStorage`; the notebook
//  (`NotebookViewController`, UIKit) reads and writes them through `UserDefaults`.
//

import Foundation

enum AppPreferences {
    enum Key {
        /// `MaterialPaneSide.rawValue` — which side of the notebook the material pane opens on.
        static let materialPaneSide = "materialPaneSide"
        /// `Double` — the material pane's share of the notebook screen's width.
        static let materialPaneFraction = "materialPaneFraction"
    }

    static let defaultMaterialPaneFraction = 0.42
    /// The pane can be dragged between these shares of the screen width.
    static let materialPaneFractionRange = 0.25...0.65
}

/// Which side of the note-taking screen course material opens on. Left by default —
/// reading on the left, writing on the right. `leading`/`trailing` rather than left/right
/// so a right-to-left layout mirrors it like the rest of the interface.
enum MaterialPaneSide: String, CaseIterable, Identifiable {
    case leading
    case trailing

    var id: String { rawValue }

    static let `default` = MaterialPaneSide.leading
}

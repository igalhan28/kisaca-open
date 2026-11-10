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
        /// `MaterialPaneSide.rawValue` — whether the material pane opens next to the
        /// sidebar or on the opposite side of the notebook.
        static let materialPaneSide = "materialPaneSide"
        /// `Double` — the material pane's share of the notebook screen's width.
        static let materialPaneFraction = "materialPaneFraction"
        /// `Bool` — keep notebook pages fitted to the screen's width, with pinch zoom off.
        /// Only the notebook; the material pane keeps its own zoom.
        static let notebookFitsWidth = "notebookFitsWidth"
        /// `Bool` — left-handed: the notebook's sidebar runs down the right edge of the
        /// screen instead of the left, away from the writing hand.
        static let leftHanded = "leftHanded"
        /// JSON `[material ID: MaterialReadingPosition]` — where each PDF was left off.
        /// Not a setting; it lives here so every key is in one place.
        static let materialReadingPositions = "materialReadingPositions"
    }

    static let defaultMaterialPaneFraction = 0.42
    /// The pane can be dragged between these shares of the screen width.
    static let materialPaneFractionRange = 0.25...0.65
}

/// Where course material opens, measured from the notebook's sidebar rather than the
/// screen: the material is an applet that slides out of the sidebar, so by default it
/// opens next to it — on the left, or on the right in left-handed mode, where the
/// sidebar is. The opposite side puts it at the far edge of the screen instead.
///
/// The raw values are the old `leading` / `trailing` (2026-11-10): with the sidebar on
/// the left, left was next to it and right opposite, so a saved choice keeps its place.
enum MaterialPaneSide: String, CaseIterable, Identifiable {
    case besideSidebar = "leading"
    case oppositeSidebar = "trailing"

    var id: String { rawValue }

    static let `default` = MaterialPaneSide.besideSidebar

    /// Whether the material lands on the left of the screen, given where the sidebar is.
    func isOnLeft(leftHanded: Bool) -> Bool {
        (self == .besideSidebar) != leftHanded
    }
}

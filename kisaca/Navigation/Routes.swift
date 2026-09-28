//
//  Routes.swift
//  kisaca
//
//  Where the app can navigate to, as plain values: today they are pushed onto the
//  SwiftUI `NavigationStack` in LibraryRootView; during the UIKit migration they become
//  what the app's navigation coordinator is asked to show (docs/uikit-migration.md).
//
//  A section of a lecture is navigated to by its `LectureSection` itself.
//

import Foundation

/// An open lecture's own screen (setup or its sections).
struct LectureRoute: Hashable {
    let lectureID: UUID
}

/// A notebook opened straight from a home-screen card, one level above its lecture.
/// Its own type — not `NotebookRoute` — because `SectionSessionsView` already
/// registers a destination for that one further down the stack.
struct LectureNotebookRoute: Hashable {
    let lectureID: UUID
    let notebook: NotebookRoute
}

/// What a `NotebookScreen` shows — the navigation value pushed from a section's list.
nonisolated struct NotebookRoute: Hashable {
    var scope: PageRepository.Scope
    /// For a whole-section notebook: the session to open at.
    var initialSessionID: UUID?
}

/// Navigation value for `MaterialsView` — there is one per lecture, so it carries nothing.
struct MaterialsRoute: Hashable {}

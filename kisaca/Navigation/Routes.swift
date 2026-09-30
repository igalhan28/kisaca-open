//
//  Routes.swift
//  kisaca
//
//  Where a notebook can open, as a plain value: `AppCoordinator` pushes a
//  `NotebookViewController` for one, from a section's list or from a home-screen card.
//
//  Lectures, sections and materials need no route type: the coordinator pushes them
//  straight from the open lecture and a section's ID (docs/uikit-migration.md).
//

import Foundation

/// What a `NotebookViewController` shows: one session, or a whole section read as one book.
nonisolated struct NotebookRoute: Hashable {
    var scope: PageRepository.Scope
    /// For a whole-section notebook: the session to open at.
    var initialSessionID: UUID?
}

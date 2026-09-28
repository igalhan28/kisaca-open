//
//  NotebookHostView.swift
//  kisaca
//
//  SwiftUI bridge that hosts `NotebookScrollViewController` — the only place UIKit
//  and SwiftUI meet for the notebook canvas. Thin by design: state flows from
//  `NotebookCoordinator` → UIKit method calls, not through SwiftUI bindings, since
//  the canvas's own scroll position/zoom state is UIKit's to own.
//

import SwiftUI
import UIKit

struct NotebookHostView: UIViewControllerRepresentable {

    let document: LectureDocument
    let scope: PageRepository.Scope
    /// For a whole-section notebook: the session to open at.
    var initialSessionID: UUID?
    @Bindable var coordinator: NotebookCoordinator

    func makeUIViewController(context: Context) -> NotebookScrollViewController {
        let repository = PageRepository(document: document, scope: scope)
        let vc = NotebookScrollViewController(repository: repository, coordinator: coordinator)
        vc.initialPageIndex = initialSessionID.flatMap { repository.firstPageIndex(of: $0) }

        coordinator.scrollVC = vc
        coordinator.pageRepository = repository
        coordinator.currentPageIndex = 0
        coordinator.totalPages = repository.pageCount

        return vc
    }

    func updateUIViewController(_ uiViewController: NotebookScrollViewController, context: Context)
    {
        // No updates needed — state flows from coordinator → scrollVC methods, not from
        // SwiftUI bindings.
    }
}

//
//  AppCoordinator.swift
//  kisaca
//
//  One window's navigation: a `UINavigationController` whose root is the home screen
//  (`LibraryViewController`). Screens navigate by calling the closures they're given
//  here; the forms that are still SwiftUI are pushed in `UIHostingController`s
//  (docs/uikit-migration.md).
//
//  Took over from LibraryRootView's `NavigationStack`: a lecture is opened before it is
//  pushed, a session card pushes the lecture and then its notebook (so Back goes
//  notebook → lecture → home), and every open lecture is saved and closed once the
//  home screen is showing again. See docs/library.md.
//

import SwiftUI
import UIKit

final class AppCoordinator: NSObject {
    let navigationController: UINavigationController

    private let library: LectureLibrary
    private let home: LibraryViewController
    /// By `OpenLecture.id`; dropped when the lectures are closed.
    private var syncs: [UUID: LectureFileSync] = [:]

    init(library: LectureLibrary) {
        self.library = library
        navigationController = AppNavigationController()
        home = LibraryViewController(library: library)
        super.init()

        home.onOpen = { [weak self] entry, session in self?.open(entry.url, session: session) }
        home.onCreate = { [weak self] in self?.createLecture() }
        home.onImported = { [weak self] urls in
            if urls.count == 1 { self?.open(urls[0], session: nil) }
        }
        home.onError = { [weak self] message in self?.showError(message) }

        navigationController.navigationBar.prefersLargeTitles = true
        navigationController.delegate = self
        navigationController.setViewControllers([home], animated: false)
    }

    /// Finds the lectures, then opens the files the window was launched with. The files
    /// wait for the library, so one that's already in it isn't imported a second time.
    func start(opening urls: [URL]) {
        Task {
            await library.start()
            for url in urls { handleOpenURL(url) }
        }
    }

    func sceneDidBecomeActive() {
        guard library.hasStarted else { return }
        library.refresh()
    }

    /// A `.kisaca` tapped in Files, or sent from another app: opened if it's one of the
    /// library's own, otherwise copied into the library first.
    func handleOpenURL(_ url: URL) {
        guard url.pathExtension == LectureLibrary.fileExtension else { return }
        if library.contains(url) {
            open(url, session: nil)
            return
        }
        Task {
            let result = await library.importLectures(from: [url])
            if let imported = result.imported.first {
                open(imported, session: nil)
            } else {
                showError(
                    "“\(url.deletingPathExtension().lastPathComponent)” couldn't be added to KISACA.")
            }
        }
    }

    // MARK: - Opening lectures

    private func open(_ url: URL, session: UUID?) {
        guard home.openingID == nil else { return }
        home.openingID = url.standardizedFileURL.path
        Task {
            defer { home.openingID = nil }
            do {
                let lecture = try await library.open(url)
                var stack: [UIViewController] = [home, lectureController(for: lecture)]
                if let session {
                    stack.append(
                        notebookController(
                            for: lecture, route: NotebookRoute(scope: .session(session))))
                }
                navigationController.setViewControllers(stack, animated: true)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func createLecture() {
        guard home.openingID == nil else { return }
        home.openingID = "new"
        Task {
            defer { home.openingID = nil }
            do {
                let lecture = try await library.createLecture()
                navigationController.pushViewController(
                    lectureController(for: lecture), animated: true)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Screens

    /// The lecture's name/file sync, one per open lecture for as long as it is open —
    /// shared by its setup form and its home screen.
    private func sync(for lecture: OpenLecture) -> LectureFileSync {
        if let sync = syncs[lecture.id] { return sync }
        let sync = LectureFileSync(document: lecture.document, file: lecture.file)
        syncs[lecture.id] = sync
        return sync
    }

    /// The setup form for a lecture that isn't set up yet, otherwise its home screen.
    private func lectureController(for lecture: OpenLecture) -> UIViewController {
        let sync = sync(for: lecture)
        guard lecture.document.manifest.needsSetup else { return lectureHome(for: lecture) }

        weak var setup: UIViewController?
        let controller = hosting(
            LectureSetupView(
                document: lecture.document, initialName: sync.suggestedSetupName,
                onCommitName: { [weak self] name in
                    sync.applyLectureName(name)
                    if let setup { self?.replace(setup, with: self?.lectureHome(for: lecture)) }
                }))
        setup = controller
        return controller
    }

    private func lectureHome(for lecture: OpenLecture) -> UIViewController {
        let controller = LectureHomeViewController(sync: sync(for: lecture))
        controller.onOpenSection = { [weak self] sectionID in
            self?.push(self?.sectionController(for: lecture, sectionID: sectionID))
        }
        controller.onOpenMaterials = { [weak self] in
            self?.push(MaterialsViewController(document: lecture.document))
        }
        return controller
    }

    private func sectionController(for lecture: OpenLecture, sectionID: UUID) -> UIViewController {
        SectionSessionsViewController(
            document: lecture.document, sectionID: sectionID,
            onOpenNotebook: { [weak self] route in
                self?.push(self?.notebookController(for: lecture, route: route))
            })
    }

    private func notebookController(for lecture: OpenLecture, route: NotebookRoute)
        -> UIViewController
    {
        let controller = NotebookViewController(document: lecture.document, route: route)
        controller.navigationItem.largeTitleDisplayMode = .never
        return controller
    }

    /// Every screen below the home screen has an inline title.
    private func hosting(_ view: some View) -> UIViewController {
        let controller = UIHostingController(rootView: view)
        controller.navigationItem.largeTitleDisplayMode = .never
        return controller
    }

    private func push(_ controller: UIViewController?) {
        guard let controller else { return }
        navigationController.pushViewController(controller, animated: true)
    }

    /// Swaps one screen on the stack for another in place, with a cross-fade — the setup
    /// form turning into the lecture's home screen once it's done.
    private func replace(_ old: UIViewController, with new: UIViewController?) {
        guard let new else { return }
        var stack = navigationController.viewControllers
        guard let index = stack.firstIndex(of: old) else { return }
        stack[index] = new
        UIView.transition(
            with: navigationController.view, duration: 0.25, options: .transitionCrossDissolve
        ) {
            self.navigationController.setViewControllers(stack, animated: false)
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: "Something Went Wrong", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        var top: UIViewController = navigationController
        while let presented = top.presentedViewController { top = presented }
        top.present(alert, animated: true)
    }
}

extension AppCoordinator: UINavigationControllerDelegate {
    /// Back at the home screen: save and close every open lecture. `didShow` only comes
    /// once a transition has completed, so a swipe back that is cancelled closes nothing.
    func navigationController(
        _ navigationController: UINavigationController, didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard viewController === home, !library.openLectures.isEmpty else { return }
        syncs = [:]
        Task { await library.closeAll() }
    }
}

/// Lets the screen on top decide whether the status bar and home indicator show —
/// the notebook hides both when its controls are tapped away — and how the status bar
/// is drawn: the notebook's sits on its black strip, so it is always white.
final class AppNavigationController: UINavigationController {
    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var childForStatusBarStyle: UIViewController? { topViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
}

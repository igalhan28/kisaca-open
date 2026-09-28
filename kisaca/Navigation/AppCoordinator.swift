//
//  AppCoordinator.swift
//  kisaca
//
//  One window's navigation: a `UINavigationController` whose root is the home screen.
//  Screens not yet converted to UIKit are SwiftUI views pushed in `UIHostingController`s
//  (docs/uikit-migration.md); they navigate by calling the closures they're given here.
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
    private let home = HomeModel()
    private var homeController: UIViewController!

    init(library: LectureLibrary) {
        self.library = library
        navigationController = UINavigationController()
        super.init()

        let homeView = HomeRoot(
            model: home,
            onOpen: { [weak self] entry, session in self?.open(entry.url, session: session) },
            onCreate: { [weak self] in self?.createLecture() },
            onImported: { [weak self] urls in
                if urls.count == 1 { self?.open(urls[0], session: nil) }
            },
            onError: { [weak self] message in self?.showError(message) }
        )
        .environment(library)
        homeController = UIHostingController(rootView: homeView)
        homeController.navigationItem.largeTitleDisplayMode = .always

        navigationController.navigationBar.prefersLargeTitles = true
        navigationController.delegate = self
        navigationController.setViewControllers([homeController], animated: false)
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
                var stack = [homeController!, lectureController(for: lecture)]
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

    private func lectureController(for lecture: OpenLecture) -> UIViewController {
        hosting(
            LectureScreen(
                document: lecture.document, file: lecture.file,
                onOpenSection: { [weak self] sectionID in
                    self?.push(self?.sectionController(for: lecture, sectionID: sectionID))
                },
                onOpenMaterials: { [weak self] in
                    self?.push(self?.hosting(MaterialsView(document: lecture.document)))
                }))
    }

    private func sectionController(for lecture: OpenLecture, sectionID: UUID) -> UIViewController {
        hosting(
            SectionSessionsView(
                document: lecture.document, sectionID: sectionID,
                onOpenNotebook: { [weak self] route in
                    self?.push(self?.notebookController(for: lecture, route: route))
                }))
    }

    private func notebookController(for lecture: OpenLecture, route: NotebookRoute)
        -> UIViewController
    {
        hosting(NotebookScreen(document: lecture.document, route: route))
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
        guard viewController === homeController, !library.openLectures.isEmpty else { return }
        Task { await library.closeAll() }
    }
}

// MARK: - Home screen (hosted)

/// What the hosted home screen shows that the coordinator changes.
@Observable
private final class HomeModel {
    /// The entry being opened, so its card can show progress and ignore a second tap.
    var openingID: String?
}

private struct HomeRoot: View {
    let model: HomeModel
    var onOpen: (LectureEntry, _ session: UUID?) -> Void
    var onCreate: () -> Void
    var onImported: ([URL]) -> Void
    var onError: (String) -> Void

    var body: some View {
        LibraryHomeView(
            openingID: model.openingID, onOpen: onOpen, onCreate: onCreate,
            onImported: onImported, onError: onError)
    }
}

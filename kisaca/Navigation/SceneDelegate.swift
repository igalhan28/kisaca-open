//
//  SceneDelegate.swift
//  kisaca
//
//  One window: its navigation (`AppCoordinator`), and the files the system hands it —
//  a `.kisaca` tapped in Files or sent from another app, including the one that
//  launched the app.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var coordinator: AppCoordinator?

    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
            let library = (UIApplication.shared.delegate as? AppDelegate)?.library
        else { return }

        let coordinator = AppCoordinator(library: library)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = coordinator.navigationController
        window.makeKeyAndVisible()
        self.window = window
        self.coordinator = coordinator

        coordinator.start(opening: connectionOptions.urlContexts.map(\.url))
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            coordinator?.handleOpenURL(context.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        coordinator?.sceneDidBecomeActive()
    }
}

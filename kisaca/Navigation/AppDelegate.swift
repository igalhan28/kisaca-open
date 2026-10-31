//
//  AppDelegate.swift
//  kisaca
//
//  The app's entry point since the UIKit migration (docs/uikit-migration.md). It owns the
//  one `LectureLibrary` every window shares and gives each window a `SceneDelegate`,
//  which builds that window's navigation (`AppCoordinator`).
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Every window lists and opens lectures through this one library.
    let library = LectureLibrary()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        replaceWindowsFromSwiftUIApp(application)
        return true
    }

    /// Windows saved while this was a SwiftUI app come back with SwiftUI's own scene
    /// delegate (`SwiftUI.AppSceneDelegate`, stored in the scene session), which shows a
    /// black window without a SwiftUI `App` — UIKit only asks
    /// `configurationForConnecting` for *new* windows, and not again when the build
    /// number changes (both checked in the simulator, 2026-09-28). Close those windows,
    /// and open a fresh one if none is left. Does something only on the first launch
    /// after the UIKit migration.
    ///
    /// Old sessions the system no longer shows anywhere (not in the app switcher) can
    /// stay listed in `openSessions` despite the request; they never connect, so they
    /// are harmless — only the ones that come back as windows matter.
    private func replaceWindowsFromSwiftUIApp(_ application: UIApplication) {
        let stale = application.openSessions.filter {
            $0.configuration.delegateClass != SceneDelegate.self
        }
        guard !stale.isEmpty else { return }
        for session in stale {
            application.requestSceneSessionDestruction(session, options: nil)
        }
        if stale.count == application.openSessions.count {
            application.activateSceneSession(
                for: UISceneSessionActivationRequest(role: .windowApplication))
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

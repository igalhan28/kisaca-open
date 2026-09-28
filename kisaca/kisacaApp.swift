//
//  kisacaApp.swift
//  kisaca
//
//  One window whose root is the home screen (LibraryRootView). Each lecture is still
//  one `.kisaca` package file — found, opened and saved by the app itself
//  (LectureLibrary, LectureFile) rather than through DocumentGroup's document browser.
//  See docs/library.md.
//

import SwiftUI

@main
struct kisacaApp: App {
    @State private var library = LectureLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryRootView()
                .environment(library)
        }
    }
}

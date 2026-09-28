//
//  LibraryRootView.swift
//  kisaca
//
//  The app's one navigation stack. Its root is the home screen (LibraryHomeView);
//  a lecture is opened before it is pushed, and every lecture still open is saved and
//  closed when the stack is back at the home screen. See docs/library.md.
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryRootView: View {
    @Environment(LectureLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    @State private var path = NavigationPath()
    /// The entry being opened, so its card can show progress and ignore a second tap.
    @State private var openingID: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            LibraryHomeView(
                openingID: openingID,
                onOpen: { entry, session in open(entry.url, session: session) },
                onCreate: createLecture,
                onImported: { urls in
                    if urls.count == 1 { open(urls[0], session: nil) }
                },
                errorMessage: $errorMessage
            )
            .navigationDestination(for: LectureRoute.self) { route in
                if let lecture = library.openLecture(withID: route.lectureID) {
                    LectureScreen(document: lecture.document, file: lecture.file)
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: LectureNotebookRoute.self) { route in
                if let lecture = library.openLecture(withID: route.lectureID) {
                    NotebookScreen(document: lecture.document, route: route.notebook)
                } else {
                    ProgressView()
                }
            }
        }
        .task { await library.start() }
        .onChange(of: path.count) { _, count in
            if count == 0 { Task { await library.closeAll() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
        // A `.kisaca` tapped in Files, or sent from another app.
        .onOpenURL { url in
            guard url.pathExtension == LectureLibrary.fileExtension else { return }
            if library.contains(url) {
                open(url, session: nil)
            } else {
                Task {
                    let result = await library.importLectures(from: [url])
                    if let imported = result.imported.first {
                        open(imported, session: nil)
                    } else {
                        errorMessage = "“\(url.deletingPathExtension().lastPathComponent)” couldn't be added to KISACA."
                    }
                }
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func open(_ url: URL, session: UUID?) {
        let id = url.standardizedFileURL.path
        guard openingID == nil else { return }
        openingID = id
        Task {
            defer { openingID = nil }
            do {
                let lecture = try await library.open(url)
                var newPath = NavigationPath()
                newPath.append(LectureRoute(lectureID: lecture.id))
                if let session {
                    newPath.append(
                        LectureNotebookRoute(
                            lectureID: lecture.id, notebook: NotebookRoute(scope: .session(session))))
                }
                path = newPath
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createLecture() {
        guard openingID == nil else { return }
        openingID = "new"
        Task {
            defer { openingID = nil }
            do {
                let lecture = try await library.createLecture()
                path.append(LectureRoute(lectureID: lecture.id))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

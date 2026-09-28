//
//  LibraryHomeView.swift
//  kisaca
//
//  The home screen: what's coming up and what just happened across every lecture,
//  then each lecture with its own sessions. Replaces the document browser DocumentGroup
//  used to show. Tapping a session opens its notebook; tapping a lecture's name opens
//  the lecture. See docs/library.md.
//

import SwiftUI
import UniformTypeIdentifiers

struct LibraryHomeView: View {
    @Environment(LectureLibrary.self) private var library

    let openingID: String?
    var onOpen: (LectureEntry, _ session: UUID?) -> Void
    var onCreate: () -> Void
    /// After an import, with the new files' URLs.
    var onImported: ([URL]) -> Void
    @Binding var errorMessage: String?

    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var pendingDeletion: LectureEntry?

    var body: some View {
        let upcoming = library.upcomingSessions()
        let recent = library.recentSessions()

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                if !upcoming.isEmpty {
                    shelf("Upcoming Sessions") {
                        ForEach(upcoming) { item in
                            card(for: item, showsLecture: true, emphasizesDay: true)
                        }
                    }
                }
                if !recent.isEmpty {
                    shelf("Last Sessions") {
                        ForEach(recent) { item in
                            card(for: item, showsLecture: true, emphasizesDay: false)
                        }
                    }
                }
                ForEach(library.entries) { entry in
                    lectureShelf(entry)
                }
            }
            .padding(.vertical, 20)
        }
        .overlay {
            if library.hasLoaded, library.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Lectures Yet", systemImage: "books.vertical")
                } description: {
                    Text("Create a lecture, or import .kisaca files you already have.")
                } actions: {
                    Button("New Lecture", action: onCreate)
                        .buttonStyle(.borderedProminent)
                    Button("Import…") { showingImporter = true }
                }
            }
        }
        .navigationTitle("KISACA")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                Button(action: onCreate) {
                    Label("New Lecture", systemImage: "plus")
                }
                .disabled(openingID != nil)
            }
        }
        .fileImporter(
            isPresented: $showingImporter, allowedContentTypes: [.kisacaLecture],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    let result = await library.importLectures(from: urls)
                    if !result.failed.isEmpty {
                        errorMessage = "Couldn't import " + result.failed.joined(separator: ", ") + "."
                    }
                    onImported(result.imported)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingSettings) {
            LibrarySettingsView()
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { entry in
            Button("Delete Lecture", role: .destructive) { delete(entry) }
        } message: { entry in
            Text(
                entry.isInICloud
                    ? "It is deleted from iCloud and all your devices, with all its notes and materials."
                    : "All its notes and materials are deleted from this device.")
        }
    }

    // MARK: - Shelves

    /// A titled row of cards scrolling sideways, starting at `initialID` if given.
    private func shelf<Title: View, Cards: View>(
        initialID: String? = nil,
        @ViewBuilder title: () -> Title, @ViewBuilder cards: () -> Cards
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title()
                .padding(.horizontal, 20)
            ShelfScrollView(initialID: initialID, content: cards())
        }
    }

    private func shelf<Cards: View>(_ title: String, @ViewBuilder cards: () -> Cards) -> some View {
        shelf(title: {
            Text(title).font(.title2.bold())
        }, cards: cards)
    }

    private func lectureShelf(_ entry: LectureEntry) -> some View {
        let sessions = library.sessions(of: entry)
        let start = Calendar.current.startOfDay(for: Date())
        let firstCurrent = sessions.first { $0.session.date >= start } ?? sessions.last

        return shelf(initialID: firstCurrent?.id, title: {
            Menu {
                Button("Open Lecture", systemImage: "book") { onOpen(entry, nil) }
                Button("Delete Lecture…", systemImage: "trash", role: .destructive) {
                    pendingDeletion = entry
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(LectureColor.color(for: entry.name))
                        .frame(width: 10, height: 10)
                    Text(entry.name)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if !entry.isInICloud, library.usesICloud {
                        Image(systemName: "icloud.slash")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Only on this device")
                    }
                }
            } primaryAction: {
                onOpen(entry, nil)
            }
            .tint(.primary)
        }, cards: {
            if sessions.isEmpty {
                PlaceholderCard(entry: entry, isOpening: openingID == entry.id)
                    .onTapGesture { onOpen(entry, nil) }
            }
            ForEach(sessions) { item in
                card(for: item, showsLecture: false, emphasizesDay: false)
            }
        })
    }

    private func card(for item: SessionItem, showsLecture: Bool, emphasizesDay: Bool)
        -> some View
    {
        Button {
            onOpen(item.lecture, item.session.id)
        } label: {
            SessionCard(
                item: item, showsLecture: showsLecture, emphasizesDay: emphasizesDay,
                isOpening: openingID == item.lecture.id)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open Lecture", systemImage: "book") { onOpen(item.lecture, nil) }
        }
    }

    private func delete(_ entry: LectureEntry) {
        Task {
            do {
                try await library.delete(entry)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A shelf's sideways scroll. Opens at the session nearest today, so a lecture's row
/// shows what's current rather than week 1.
private struct ShelfScrollView<Content: View>: View {
    let initialID: String?
    let content: Content

    @State private var position: String?
    /// Set once the row has been moved to `initialID`; after that, it's the user's.
    @State private var didScrollToInitial = false

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                content
            }
            .scrollTargetLayout()
        }
        // A margin rather than padding, so a card scrolled to the start lines up with it.
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollPosition(id: $position, anchor: .leading)
        .scrollIndicators(.hidden)
        // `initialID` is nil until the lecture's manifest has been read.
        .onChange(of: initialID, initial: true) { _, id in
            guard !didScrollToInitial, let id else { return }
            position = id
            didScrollToInitial = true
        }
    }
}

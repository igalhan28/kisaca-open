//
//  SectionSessionsView.swift
//  kisaca
//
//  Middle level of Lecture → Section → Session. Lists the sessions inside one
//  section and lets the user add one by hand. Three things beyond a plain list:
//
//  - **Whole notebook.** The first row opens every session of the section as one
//    continuous notebook — all of the course's lecture notes, Monday's and
//    Thursday's alike, in order — see `PageRepository.Scope.section`.
//  - **Weeks.** A weekly-named section in a lecture with a semester is grouped by
//    semester week, and the list opens scrolled to the current one.
//  - **Titles** follow the section's naming ("W3 · Mon", "Assignment 3") —
//    `LectureManifest.title(for:)`.
//
//  Sessions for the semester are generated from the lecture's routine
//  (`LectureManifest.generateSessions`); the "+" here is for anything outside it —
//  a make-up lecture, an extra exercise sheet.
//

import SwiftUI

struct SectionSessionsView: View {
    let document: LectureDocument
    let sectionID: UUID

    @State private var showingAddSession = false
    @State private var newSessionDate = Date()
    @State private var sessionPendingDeletion: LectureSession?

    private var section: LectureSection? {
        document.manifest.section(withID: sectionID)
    }

    private var sessions: [LectureSession] {
        document.manifest.sessions(inSectionWithID: sectionID)
    }

    /// Sessions grouped for display: by semester week for a weekly-named section in a
    /// lecture with a semester, otherwise one group.
    private var groups: [SessionGroup] {
        guard section?.naming == .weekly, let semester = document.manifest.semester else {
            return [SessionGroup(id: "all", week: nil, sessions: sessions)]
        }
        var byWeek: [Int: [LectureSession]] = [:]
        var outside: [LectureSession] = []
        for session in sessions {
            if let week = semester.week(of: session.date) {
                byWeek[week, default: []].append(session)
            } else {
                outside.append(session)
            }
        }
        var groups = byWeek.keys.sorted().map {
            SessionGroup(id: "week-\($0)", week: $0, sessions: byWeek[$0] ?? [])
        }
        if !outside.isEmpty {
            groups.append(SessionGroup(id: "outside", week: nil, sessions: outside))
        }
        return groups
    }

    private var currentWeek: Int? {
        document.manifest.semester?.week(of: Date())
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                wholeNotebookRow

                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            NavigationLink(value: NotebookRoute(scope: .session(session.id))) {
                                SessionRow(document: document, session: session)
                            }
                            .contextMenu {
                                Button("Delete Session", systemImage: "trash", role: .destructive) {
                                    sessionPendingDeletion = session
                                }
                            }
                        }
                    } header: {
                        header(for: group)
                    }
                    .id(group.id)
                }
            }
            .onAppear {
                // Not for the first week: the list already starts there, and scrolling
                // would only push the Whole Notebook row out of sight.
                if let week = currentWeek, groups.first?.week != week,
                    groups.contains(where: { $0.week == week })
                {
                    // Not `.top`: that tucks the week's header under the navigation bar.
                    proxy.scrollTo("week-\(week)", anchor: UnitPoint(x: 0.5, y: 0.1))
                }
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions Yet",
                    systemImage: "square.and.pencil",
                    description: Text(
                        "Add a session, or set the semester and meeting times from the lecture's calendar button to create them all at once."
                    )
                )
            }
        }
        .navigationTitle(section?.name ?? "Section")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: NotebookRoute.self) { route in
            NotebookScreen(document: document, route: route)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newSessionDate = suggestedNextDate()
                    showingAddSession = true
                } label: {
                    Label("Add Session", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSession) {
            NavigationStack {
                Form {
                    DatePicker("Date", selection: $newSessionDate)
                }
                .navigationTitle("New Session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddSession = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { addSession() }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }),
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete", role: .destructive) { document.deleteSession(withID: session.id) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text(deletionMessage(for: session))
        }
    }

    // MARK: - Whole notebook

    @ViewBuilder
    private var wholeNotebookRow: some View {
        // An upcoming session joins once it has notes — page data isn't observed itself.
        let _ = document.pageContentRevision
        let included = PageRepository.notebookSessions(inSection: sectionID, of: document)
        if let latest = included.last {
            Section {
                NavigationLink(
                    value: NotebookRoute(scope: .section(sectionID), initialSessionID: latest.id)
                ) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Whole Notebook")
                            let pages = included.reduce(0) { $0 + $1.pageIDs.count }
                            Text(
                                "\(included.count) session\(included.count == 1 ? "" : "s") · \(pages) page\(pages == 1 ? "" : "s") as one book"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "books.vertical")
                    }
                }
            } footer: {
                Text("Opens at the latest session. Upcoming sessions join once they start or have notes.")
            }
        }
    }

    // MARK: - Headers

    @ViewBuilder
    private func header(for group: SessionGroup) -> some View {
        if let week = group.week {
            HStack {
                Text("Week \(week)")
                if let range = document.manifest.semester?.dateRange(ofWeek: week) {
                    Text(
                        "\(range.lowerBound.formatted(.dateTime.day().month())) – \(range.upperBound.formatted(.dateTime.day().month()))"
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if week == currentWeek {
                    Text("This Week")
                        .foregroundStyle(.tint)
                }
            }
        } else if group.id == "outside" {
            Text("Outside the Semester")
        }
    }

    // MARK: - Actions

    /// The section's next scheduled meeting from now on, if it has meeting times;
    /// otherwise now.
    private func suggestedNextDate() -> Date {
        guard let section else { return Date() }
        return document.manifest.schedule(for: section)
            .map { $0.nextOccurrence() }
            .min() ?? Date()
    }

    private func deletionMessage(for session: LectureSession) -> String {
        let title = document.manifest.title(for: session)
        let written = session.pageIDs.filter { document.getPageData(for: $0) != nil }.count
        let notes =
            written == 0
            ? "" : " and its \(written) page\(written == 1 ? "" : "s") of notes"
        return "“\(title)”\(notes) will be permanently deleted."
    }

    private func addSession() {
        guard let section else { return }
        document.manifest.sessions.append(
            LectureSession(sectionID: section.id, date: newSessionDate))
        showingAddSession = false
    }
}

private struct SessionGroup: Identifiable {
    let id: String
    let week: Int?
    let sessions: [LectureSession]
}

/// One session: its title, date, and how much is in it. Today's session is marked;
/// upcoming ones are dimmed.
private struct SessionRow: View {
    let document: LectureDocument
    let session: LectureSession

    var body: some View {
        let isToday = Calendar.current.isDateInToday(session.date)
        let isUpcoming = !isToday && session.date > Date()
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.manifest.title(for: session))
                    .foregroundStyle(isUpcoming ? .secondary : .primary)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isToday {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    private var details: String {
        let pages = "\(session.pageIDs.count) page\(session.pageIDs.count == 1 ? "" : "s")"
        _ = document.pageContentRevision  // page data isn't observed itself
        let hasNotes = session.pageIDs.contains { document.getPageData(for: $0) != nil }
        let parts = [
            document.manifest.subtitle(for: session),
            session.date.formatted(date: .omitted, time: .shortened),
            hasNotes ? pages : "No notes yet",
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

#Preview {
    let doc = LectureDocument()
    let section = LectureSection.recommendedDefaults()[0]
    doc.manifest.sections = [section]
    doc.manifest.semester = Semester(
        startDate: Date().addingTimeInterval(-21 * 86400),
        endDate: Date().addingTimeInterval(70 * 86400))
    doc.manifest.schedule = [
        ScheduleSlot(sectionID: section.id, weekday: 2, startHour: 10, startMinute: 0),
        ScheduleSlot(sectionID: section.id, weekday: 5, startHour: 14, startMinute: 0),
    ]
    doc.manifest.generateSessions()
    return NavigationStack {
        SectionSessionsView(document: doc, sectionID: section.id)
    }
}

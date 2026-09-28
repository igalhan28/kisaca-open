//
//  LectureHomeView.swift
//  kisaca
//
//  Top level of the main interface skeleton described in the project brief:
//  Lecture (this screen) → Section → Session (dated notebook), plus the lecture's
//  Materials (its files) in their own row at the top. Shown once
//  `document.manifest.needsSetup` is false — see ContentView.swift.
//
//  This is the root of the app's single navigation bar (ContentView owns the
//  NavigationStack and hides DocumentGroup's own bar), so it re-hosts the renameable
//  document title. Back-to-the-browser is the system's own close chevron, which
//  DocumentGroup places in this bar's leading position — this view deliberately adds
//  no back button of its own, or the two sit side by side doing the same thing.
//  Everything below this screen just gets the ordinary hierarchical back button for free.
//

import SwiftUI

/// Navigation value for `MaterialsView` — there is one per lecture, so it carries nothing.
struct MaterialsRoute: Hashable {}

struct LectureHomeView: View {
    @ObservedObject var document: LectureDocument
    /// Renames the lecture *and* its file — ContentView.applyLectureName.
    var onRename: (String) -> Void

    @State private var showingAddSection = false
    @State private var showingRoutine = false
    @State private var newSectionName = ""

    /// Drives the title menu's "Rename": reads the lecture name, and writes through
    /// the same funnel the setup form uses, so the file name follows along.
    private var lectureName: Binding<String> {
        Binding(
            get: { document.manifest.name },
            set: { onRename($0) }
        )
    }

    var body: some View {
        List {
            materialsRow

            Section {
            ForEach(document.manifest.sections(sortedBySortOrder: true)) { section in
                NavigationLink(value: section) {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.name)
                                if let next = nextSessionText(in: section) {
                                    Text(next)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: section.symbolName)
                        }
                        Spacer()
                        let count = document.manifest.sessions(in: section).count
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            }
        }
        .overlay {
            if document.manifest.sections.isEmpty {
                ContentUnavailableView(
                    "No Sections Yet",
                    systemImage: "folder.badge.plus",
                    description: Text("Add a section like \"Lectures\" or \"Labs\" to get started.")
                )
            }
        }
        .navigationTitle(lectureName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: LectureSection.self) { section in
            SectionSessionsView(document: document, sectionID: section.id)
        }
        .navigationDestination(for: MaterialsRoute.self) { _ in
            MaterialsView(document: document)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingRoutine = true
                } label: {
                    Label("Semester & Schedule", systemImage: "calendar")
                }
                Button {
                    showingAddSection = true
                } label: {
                    Label("Add Section", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingRoutine) {
            RoutineSheet(document: document)
        }
        .alert("New Section", isPresented: $showingAddSection) {
            TextField("Section name", text: $newSectionName)
            Button("Cancel", role: .cancel) { newSectionName = "" }
            Button("Add") { addSection() }
        }
    }

    /// The lecture's files, in their own row above the sections — the lecture-level
    /// counterpart of a section's Whole Notebook row.
    private var materialsRow: some View {
        Section {
            NavigationLink(value: MaterialsRoute()) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Materials")
                        Text(materialsSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "tray.full")
                }
            }
        } footer: {
            Text("Scripts, slides and exercise sheets, kept inside this lecture's file.")
        }
    }

    private var materialsSummary: String {
        let list = document.manifest.materialList
        guard !list.isEmpty else { return "No files yet" }
        let bytes = list.reduce(0) { $0 + $1.byteCount }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(list.count) file\(list.count == 1 ? "" : "s") · \(size)"
    }

    /// "Next: W3 · Thu, 10:00" — the section's next session from now on, if any.
    private func nextSessionText(in section: LectureSection) -> String? {
        let now = Calendar.current.startOfDay(for: Date())
        guard let next = document.manifest.sessions(in: section).first(where: { $0.date >= now })
        else { return nil }
        let time = next.date.formatted(date: .omitted, time: .shortened)
        let isToday = Calendar.current.isDateInToday(next.date)
        // A title without a semester week already carries the date ("Thu · 24.09.2026").
        let titleHasDate = document.manifest.subtitle(for: next) == nil
        let day =
            isToday
            ? "Today, " : titleHasDate ? "" : next.date.formatted(.dateTime.day().month()) + ", "
        return "Next: \(document.manifest.title(for: next)) · \(day)\(time)"
    }

    private func addSection() {
        let trimmedName = newSectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        newSectionName = ""
        guard !trimmedName.isEmpty else { return }
        let nextOrder = (document.manifest.sections.map(\.sortOrder).max() ?? -1) + 1
        document.manifest.sections.append(
            LectureSection(name: trimmedName, symbolName: "folder", sortOrder: nextOrder)
        )
    }
}

#Preview {
    let doc = LectureDocument()
    doc.manifest.name = "Calculus II"
    doc.manifest.sections = LectureSection.recommendedDefaults()
    return NavigationStack {
        LectureHomeView(doc: doc)
    }
}

extension LectureHomeView {
    /// Preview-only convenience.
    fileprivate init(doc: LectureDocument) {
        self.init(document: doc, onRename: { _ in })
    }
}

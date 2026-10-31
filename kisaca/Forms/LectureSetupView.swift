//
//  LectureSetupView.swift
//  kisaca
//
//  Shown once, in place of the lecture's home screen, for a freshly-created document
//  (`document.manifest.needsSetup == true`). `AppCoordinator` pushes it in a
//  `UIHostingController` and swaps it for the home screen once "Create" is tapped. One of
//  the forms that stays SwiftUI for now (docs/uikit-migration.md → Phase 5).
//
//  Covers everything the project brief asks for at lecture-creation time:
//  the lecture name, the sections (recommended defaults + custom, editable inline,
//  swipe-to-delete to exclude one), and the lecture's routine — semester dates, how
//  each section names its sessions, and its weekly meeting times (`RoutineEditor`).
//  With a semester and meeting times, "Create" generates the semester's sessions.
//
//  This is a single-screen Form for the MVP rather than a multi-step wizard — noted
//  in ARCHITECTURE.md as a place to revisit for polish, not a functional gap.
//
//  The name typed here is the lecture's *only* name: "Create" hands it to
//  `LectureFileSync.applyLectureName`, which also renames the document's file to match —
//  it is not a second, parallel name alongside the file's.
//

import SwiftUI

struct LectureSetupView: View {
    let document: LectureDocument
    /// Pre-fill for the name field — the file's own name when it already has a real one,
    /// otherwise empty. See `LectureFileSync.suggestedSetupName`.
    var initialName: String = ""
    /// Sets the lecture name *and* renames the document file to match.
    var onCommitName: (String) -> Void

    @State private var lectureName: String = ""
    @State private var sections: [LectureSection] = LectureSection.recommendedDefaults()
    @State private var customSectionDraft: String = ""
    @State private var routine = RoutineDraft()

    var body: some View {
        Form {
            Section {
                TextField("e.g. Calculus II", text: $lectureName)
                    .textInputAutocapitalization(.words)
            } header: {
                Text("Lecture Name")
            } footer: {
                Text("This is also the document's file name — renaming one renames the other.")
            }

            Section {
                ForEach($sections) { $section in
                    HStack {
                        Image(systemName: section.symbolName)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        TextField("Section name", text: $section.name)
                    }
                }
                .onDelete { sections.remove(atOffsets: $0) }

                HStack {
                    TextField("Add custom section…", text: $customSectionDraft)
                    Button("Add") { addCustomSection() }
                        .disabled(trimmed(customSectionDraft).isEmpty)
                }
            } header: {
                Text("Sections")
            } footer: {
                Text(
                    "Lectures, Exercise Sessions, Labs, and Assignments are recommended — rename, delete, or add your own."
                )
            }

            RoutineEditorSections(sections: sections, draft: $routine)
        }
        .navigationTitle("New Lecture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { createLecture() }
                    .disabled(trimmed(lectureName).isEmpty || sections.isEmpty || !routine.isValid)
            }
        }
        .onAppear {
            if lectureName.isEmpty { lectureName = initialName }
        }
    }

    // MARK: - Actions

    private func addCustomSection() {
        let name = trimmed(customSectionDraft)
        guard !name.isEmpty else { return }
        sections.append(LectureSection(name: name, symbolName: "folder", sortOrder: sections.count))
        // A section named like "Homework" or "Sheets" still starts out weekly; the
        // routine form lets the user switch it to numbered.
        customSectionDraft = ""
    }

    private func createLecture() {
        var finalSections = sections
        for i in finalSections.indices { finalSections[i].sortOrder = i }

        // One assignment, so the document is marked dirty once.
        var manifest = document.manifest
        manifest.sections = finalSections
        manifest.schedule = []
        routine.apply(to: &manifest)  // semester, naming, schedule, generated sessions
        manifest.needsSetup = false
        document.manifest = manifest
        // Sets manifest.name AND renames the file to match — one name, one funnel.
        onCommitName(trimmed(lectureName))
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    NavigationStack {
        LectureSetupView(
            document: LectureDocument(), onCommitName: { _ in })
    }
}

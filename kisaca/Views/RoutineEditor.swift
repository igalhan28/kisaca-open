//
//  RoutineEditor.swift
//  kisaca
//
//  A lecture's routine: the semester's dates, and for each section how its sessions
//  are named and when it meets each week. Edited in two places with the same form —
//  while creating a lecture (`LectureSetupView`) and afterwards from the lecture's
//  home screen (`RoutineSheet`) — so a lecture created before routines existed, or
//  whose timetable changed, can still get its semester of sessions.
//

import SwiftUI

/// Transient editing state for a routine. Built from, and applied back to, a manifest.
struct RoutineDraft {
    struct Slot: Identifiable, Hashable {
        var id = UUID()
        var weekday = 2  // Monday; `Calendar` convention, 1 = Sunday
        var startHour = 10
        var startMinute = 0
        var endHour = 12
        var endMinute = 0
    }

    struct SectionRoutine {
        var naming: SessionNaming
        var numberPrefix: String
        var slots: [Slot] = []
    }

    var semesterEnabled = false
    var semesterStart = Calendar.current.startOfDay(for: Date())
    var semesterEnd =
        Calendar.current.date(
            byAdding: .weekOfYear, value: 14, to: Calendar.current.startOfDay(for: Date()))
        ?? Date()
    var sections: [UUID: SectionRoutine] = [:]

    init() {}

    /// The routine `manifest` currently has.
    init(manifest: LectureManifest) {
        if let semester = manifest.semester {
            semesterEnabled = true
            semesterStart = semester.startDate
            semesterEnd = semester.endDate
        }
        for section in manifest.sections {
            sections[section.id] = SectionRoutine(
                naming: section.naming,
                numberPrefix: section.numberPrefix,
                slots: manifest.schedule(for: section).map {
                    Slot(
                        id: $0.id, weekday: $0.weekday,
                        startHour: $0.startHour, startMinute: $0.startMinute,
                        endHour: $0.endHour ?? $0.startHour + 1,
                        endMinute: $0.endMinute ?? $0.startMinute)
                })
        }
    }

    func routine(for section: LectureSection) -> SectionRoutine {
        sections[section.id]
            ?? SectionRoutine(naming: section.naming, numberPrefix: section.numberPrefix)
    }

    var isValid: Bool { !semesterEnabled || semesterStart <= semesterEnd }

    /// Writes semester, naming and schedule into `manifest` for `sections`, then
    /// generates the semester's sessions. Additive: sessions of a removed meeting
    /// time stay, since they may already hold notes. Returns how many were added.
    @discardableResult
    func apply(to manifest: inout LectureManifest) -> Int {
        manifest.semester =
            semesterEnabled ? Semester(startDate: semesterStart, endDate: semesterEnd) : nil
        for i in manifest.sections.indices {
            let routine = routine(for: manifest.sections[i])
            manifest.sections[i].naming = routine.naming
            let prefix = routine.numberPrefix.trimmingCharacters(in: .whitespaces)
            manifest.sections[i].numberPrefix =
                prefix.isEmpty
                ? LectureSection.defaultPrefix(forName: manifest.sections[i].name) : prefix
        }
        let sectionIDs = Set(manifest.sections.map(\.id))
        manifest.schedule.removeAll { sectionIDs.contains($0.sectionID) }
        for section in manifest.sections {
            for slot in routine(for: section).slots {
                manifest.schedule.append(
                    ScheduleSlot(
                        id: slot.id, sectionID: section.id, weekday: slot.weekday,
                        startHour: slot.startHour, startMinute: slot.startMinute,
                        endHour: slot.endHour, endMinute: slot.endMinute))
            }
        }
        return manifest.generateSessions()
    }
}

/// The routine form's sections, to be placed inside a `Form`.
struct RoutineEditorSections: View {
    let sections: [LectureSection]
    @Binding var draft: RoutineDraft

    var body: some View {
        Section {
            Toggle("Set semester dates", isOn: $draft.semesterEnabled)
            if draft.semesterEnabled {
                DatePicker("Starts", selection: $draft.semesterStart, displayedComponents: .date)
                DatePicker("Ends", selection: $draft.semesterEnd, displayedComponents: .date)
                if let weeks = weekCount {
                    LabeledContent("Length", value: "\(weeks) week\(weeks == 1 ? "" : "s")")
                }
            }
        } header: {
            Text("Semester")
        } footer: {
            Text(
                draft.semesterEnabled
                    ? "Every meeting time below becomes a session for each week of the semester. Week 1 is the week the semester starts."
                    : "Without semester dates, meeting times only suggest the date of a session you add yourself."
            )
        }

        ForEach(sections) { section in
            sectionEditor(section)
        }
    }

    private var weekCount: Int? {
        guard draft.isValid else { return nil }
        return Semester(startDate: draft.semesterStart, endDate: draft.semesterEnd).weekCount
    }

    @ViewBuilder
    private func sectionEditor(_ section: LectureSection) -> some View {
        let routine = Binding<RoutineDraft.SectionRoutine>(
            get: { draft.routine(for: section) },
            set: { draft.sections[section.id] = $0 })

        Section {
            Picker("Session names", selection: routine.naming) {
                Text("By week · W1 · Mon").tag(SessionNaming.weekly)
                Text("Numbered · \(routine.wrappedValue.numberPrefix) 1").tag(SessionNaming.numbered)
            }
            if routine.wrappedValue.naming == .numbered {
                LabeledContent("Name") {
                    TextField("Assignment", text: routine.numberPrefix)
                        .multilineTextAlignment(.trailing)
                }
            }

            ForEach(routine.slots) { $slot in
                SlotRow(slot: $slot)
            }
            .onDelete { routine.wrappedValue.slots.remove(atOffsets: $0) }

            Button {
                var slot = RoutineDraft.Slot()
                // A second meeting defaults to a different day than the last one.
                if let last = routine.wrappedValue.slots.last {
                    slot = last
                    slot.id = UUID()
                    slot.weekday = last.weekday == 7 ? 1 : last.weekday + 1
                }
                routine.wrappedValue.slots.append(slot)
            } label: {
                Label("Add Meeting Time", systemImage: "plus.circle")
            }
        } header: {
            Label(section.name, systemImage: section.symbolName)
        }
    }
}

/// One weekly meeting: day, start and end time.
private struct SlotRow: View {
    @Binding var slot: RoutineDraft.Slot

    var body: some View {
        HStack {
            Picker("Day", selection: $slot.weekday) {
                ForEach(orderedWeekdays, id: \.self) { day in
                    Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            DatePicker(
                "Start", selection: time(\.startHour, \.startMinute),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            Text("–").foregroundStyle(.secondary)
            DatePicker(
                "End", selection: time(\.endHour, \.endMinute), displayedComponents: .hourAndMinute
            )
            .labelsHidden()
        }
        // The row's separator would otherwise start under the last text it finds (the
        // end time) instead of at the row's leading edge.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    /// Weekdays in the user's week order (Monday first in most locales).
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func time(
        _ hour: WritableKeyPath<RoutineDraft.Slot, Int>,
        _ minute: WritableKeyPath<RoutineDraft.Slot, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: slot[keyPath: hour], minute: slot[keyPath: minute], second: 0,
                    of: Date()) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                slot[keyPath: hour] = comps.hour ?? 0
                slot[keyPath: minute] = comps.minute ?? 0
            })
    }
}

/// Edits an existing lecture's routine, from its home screen.
struct RoutineSheet: View {
    @ObservedObject var document: LectureDocument
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoutineDraft

    init(document: LectureDocument) {
        self.document = document
        _draft = State(initialValue: RoutineDraft(manifest: document.manifest))
    }

    var body: some View {
        NavigationStack {
            Form {
                RoutineEditorSections(
                    sections: document.manifest.sections(sortedBySortOrder: true), draft: $draft)
            }
            .navigationTitle("Semester & Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.isValid)
                }
            }
        }
    }

    private func save() {
        // One assignment, so the document is marked dirty once, not once per field.
        var manifest = document.manifest
        draft.apply(to: &manifest)
        document.manifest = manifest
        dismiss()
    }
}

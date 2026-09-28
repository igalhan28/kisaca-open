//
//  LectureModels.swift
//  kisaca
//
//  Codable data model for one Lecture document. See docs/data-model.md
//  for the full picture. Everything here is persisted as `manifest.json` inside the
//  `.kisaca` package by `LectureDocument`.
//
//  All types here are explicitly `nonisolated`: the project's default actor isolation
//  is MainActor (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), which would otherwise
//  make these plain data structs MainActor-isolated too, and their `Codable`
//  conformances unusable from any nonisolated context (e.g. background encoding,
//  or a future off-main-actor save path). Pure value types like these have no reason
//  to be actor-isolated at all — isolation belongs on the mutable reference types
//  that own them (`LectureDocument`), not on the data itself.
//

import Foundation

// MARK: - LectureSection

/// A category within a lecture, e.g. "Exercise Sessions". Purely organizational —
/// holds no pages itself; `LectureSession`s reference a section by `sectionID`.
///
/// Named `LectureSection` (not bare `Section`) to avoid clashing with SwiftUI's
/// `Section` view type.
nonisolated struct LectureSection: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// SF Symbol name shown next to the section in lists.
    var symbolName: String
    /// Controls display order within the lecture (lower = earlier).
    var sortOrder: Int
    /// How this section's sessions are titled — see `SessionNaming`.
    var naming: SessionNaming
    /// The word in front of the number for `.numbered` naming ("Assignment" →
    /// "Assignment 3"). Unused for `.weekly`.
    var numberPrefix: String

    init(
        id: UUID = UUID(), name: String, symbolName: String, sortOrder: Int,
        naming: SessionNaming = .weekly, numberPrefix: String? = nil
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.naming = naming
        self.numberPrefix = numberPrefix ?? Self.defaultPrefix(forName: name)
    }

    /// The four use-cases recommended in the project brief. Offered as pre-checked
    /// suggestions during lecture setup; the user can deselect any and/or add custom ones.
    /// Each carries its own naming logic: meetings are titled by week and weekday
    /// ("W3 · Mon"), assignments by number ("Assignment 3").
    static func recommendedDefaults() -> [LectureSection] {
        [
            LectureSection(name: "Lectures", symbolName: "book", sortOrder: 0),
            LectureSection(name: "Exercise Sessions", symbolName: "pencil.and.ruler", sortOrder: 1),
            LectureSection(name: "Labs", symbolName: "flask", sortOrder: 2),
            LectureSection(
                name: "Assignments", symbolName: "checklist", sortOrder: 3,
                naming: .numbered, numberPrefix: "Assignment"),
        ]
    }

    /// "Assignments" → "Assignment", "Exercise Sheets" → "Exercise Sheet".
    static func defaultPrefix(forName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 1, trimmed.hasSuffix("s") { return String(trimmed.dropLast()) }
        return trimmed.isEmpty ? "No." : trimmed
    }

    // Manifests written before `naming`/`numberPrefix` existed decode with the naming
    // the recommended defaults would have given them: the old "Assignments" section
    // (the only one using the `checklist` symbol) becomes numbered, everything else weekly.
    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, sortOrder, naming, numberPrefix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbolName = try c.decode(String.self, forKey: .symbolName)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        naming =
            try c.decodeIfPresent(SessionNaming.self, forKey: .naming)
            ?? (symbolName == "checklist" ? .numbered : .weekly)
        numberPrefix =
            try c.decodeIfPresent(String.self, forKey: .numberPrefix)
            ?? Self.defaultPrefix(forName: name)
    }
}

// MARK: - SessionNaming

/// How a section titles its sessions.
nonisolated enum SessionNaming: String, Codable, CaseIterable, Hashable {
    /// By semester week and weekday: "W3 · Mon". Falls back to the date when the
    /// lecture has no semester, or the session falls outside it.
    case weekly
    /// By running number in date order: "Assignment 3".
    case numbered
}

// MARK: - Semester

/// The lecture's teaching period. Week 1 is the calendar week containing
/// `startDate`; weeks follow the user's calendar (Monday-first in most locales).
nonisolated struct Semester: Codable, Hashable {
    var startDate: Date
    var endDate: Date

    /// 1-based week of `date` within the semester, or `nil` outside it.
    func week(of date: Date, calendar: Calendar = .current) -> Int? {
        guard let first = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start,
            let this = calendar.dateInterval(of: .weekOfYear, for: date)?.start,
            date <= Self.endOfDay(endDate, calendar: calendar)
        else { return nil }
        let weeks = calendar.dateComponents([.weekOfYear], from: first, to: this).weekOfYear ?? -1
        return weeks >= 0 ? weeks + 1 : nil
    }

    var weekCount: Int { week(of: endDate) ?? 0 }

    /// First and last day of week `n`.
    func dateRange(ofWeek n: Int, calendar: Calendar = .current) -> ClosedRange<Date>? {
        guard let first = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start,
            let start = calendar.date(byAdding: .weekOfYear, value: n - 1, to: first),
            let end = calendar.date(byAdding: .day, value: 6, to: start)
        else { return nil }
        return start...end
    }

    static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .day, for: date)?.end ?? date
    }
}

// MARK: - ScheduleSlot

/// A recurring weekly meeting time for a section (e.g. "Exercise Sessions meet every
/// Tuesday 10:00–12:00"). A section can have several (Lectures on Monday *and*
/// Thursday). With a `Semester` set, `LectureManifest.generateSessions()` creates one
/// session per occurrence; without one, a slot only pre-fills the date of a new session.
nonisolated struct ScheduleSlot: Codable, Identifiable, Hashable {
    var id: UUID
    var sectionID: UUID
    /// `Calendar` weekday convention: 1 = Sunday ... 7 = Saturday.
    var weekday: Int
    var startHour: Int
    var startMinute: Int
    var endHour: Int?
    var endMinute: Int?

    init(
        id: UUID = UUID(), sectionID: UUID, weekday: Int,
        startHour: Int, startMinute: Int,
        endHour: Int? = nil, endMinute: Int? = nil
    ) {
        self.id = id
        self.sectionID = sectionID
        self.weekday = weekday
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
    }

    /// Short display string, e.g. "Tue · 10:00–12:00" or "Tue · 10:00".
    var displayString: String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let day = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
        let start = String(format: "%02d:%02d", startHour, startMinute)
        if let endHour, let endMinute {
            return "\(day) · \(start)–\(String(format: "%02d:%02d", endHour, endMinute))"
        }
        return "\(day) · \(start)"
    }

    /// The next date (today or later) that falls on this slot's weekday, at this slot's time.
    func nextOccurrence(after reference: Date = Date()) -> Date {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = startHour
        comps.minute = startMinute
        return cal.nextDate(
            after: reference, matching: comps, matchingPolicy: .nextTime,
            direction: .forward
        ) ?? reference
    }
}

// MARK: - LectureSession

/// One dated notebook instance inside a section, e.g. "29.10.2026" under "Exercise
/// Sessions". This is what actually owns pages — `pageIDs` indexes into
/// `LectureDocument.pageData` (see docs/document-format.md).
nonisolated struct LectureSession: Codable, Identifiable, Hashable {
    var id: UUID
    var sectionID: UUID
    var date: Date
    /// Optional custom title; when nil, UI displays the formatted `date`.
    var title: String?
    /// Ordered page IDs — index 0 is the first page. Always has at least one entry.
    var pageIDs: [UUID]
    var createdAt: Date
    /// Side of this session's grid squares, in millimetres. Absent in sessions written
    /// before the grid size was stored: those were written on the old 5 mm grid and stay
    /// on it, so their ink keeps lining up with the lines. Read through `gridSpacingMM`.
    var storedGridSpacingMM: Double?

    /// The grid new sessions get.
    static let defaultGridSpacingMM = 6.5
    /// The grid every session had before the size was stored.
    static let legacyGridSpacingMM = 5.0

    var gridSpacingMM: Double { storedGridSpacingMM ?? Self.legacyGridSpacingMM }

    init(
        id: UUID = UUID(), sectionID: UUID, date: Date, title: String? = nil,
        pageIDs: [UUID]? = nil, createdAt: Date = Date(),
        gridSpacingMM: Double = LectureSession.defaultGridSpacingMM
    ) {
        self.id = id
        self.sectionID = sectionID
        self.date = date
        self.title = title
        self.pageIDs = pageIDs ?? [UUID()]
        self.createdAt = createdAt
        self.storedGridSpacingMM = gridSpacingMM
    }

    private enum CodingKeys: String, CodingKey {
        case id, sectionID, date, title, pageIDs, createdAt
        case storedGridSpacingMM = "gridSpacingMM"
    }

    /// "29.10.2026" — matches the format used in the project brief.
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    /// Date-only title. Prefer `LectureManifest.title(for:)`, which applies the
    /// section's naming ("W3 · Mon", "Assignment 3") and falls back to this.
    var displayTitle: String {
        title ?? Self.dateFormatter.string(from: date)
    }
}

// MARK: - SkippedMeeting

/// A meeting whose session the user deleted. `LectureManifest.generateSessions()` leaves
/// it out, so a deleted session doesn't come back the next time the routine is saved.
nonisolated struct SkippedMeeting: Codable, Hashable {
    var sectionID: UUID
    var date: Date
}

// MARK: - CourseMaterial

/// One file the student added to the lecture: a script, lecture slides, an exercise
/// sheet PDF. The manifest holds only this description; the file itself is stored in
/// the document package as `Materials/<storedFileName>`.
nonisolated struct CourseMaterial: Codable, Identifiable, Hashable {
    var id: UUID
    /// Shown in the list; starts as the imported file's name without its extension.
    var title: String
    /// The name the file had when it was imported, e.g. "Analysis II Script.pdf" —
    /// used again when the file is previewed or shared, so it keeps its real name.
    var originalFileName: String
    /// `UTType` identifier, e.g. "com.adobe.pdf". Picks the icon.
    var contentTypeIdentifier: String?
    var byteCount: Int
    var addedAt: Date
    /// Semester week (1-based) the file belongs to — that week's slides or exercise
    /// sheet. `nil` = the whole lecture (script, syllabus). Absent in older manifests.
    var week: Int?

    init(
        id: UUID = UUID(), title: String, originalFileName: String,
        contentTypeIdentifier: String?, byteCount: Int, addedAt: Date = Date(),
        week: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.originalFileName = originalFileName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.addedAt = addedAt
        self.week = week
    }

    /// Name inside the package: the ID, not the user's file name, so two imports
    /// called "Script.pdf" can't collide and no file name can be illegal on disk.
    var storedFileName: String {
        let ext = (originalFileName as NSString).pathExtension
        return ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
    }
}

// MARK: - LectureManifest

/// The full persisted state of one lecture document (`manifest.json`).
nonisolated struct LectureManifest: Codable {
    /// Bump if the on-disk shape changes in a way old files can't decode directly.
    var schemaVersion: Int = 1

    var name: String
    /// Optional accent color name (SwiftUI `Color` name), reserved for future theming.
    var colorTag: String?
    /// True until the user completes `LectureSetupView` once for this document.
    var needsSetup: Bool

    var sections: [LectureSection]
    var schedule: [ScheduleSlot]
    var sessions: [LectureSession]
    /// Optional; absent in manifests written before semesters existed.
    var semester: Semester?
    /// Optional; absent until the first session is deleted. See `removeSession(withID:)`.
    var skippedMeetings: [SkippedMeeting]?
    /// The lecture's own files — scripts, slides, exercise sheets. Optional; absent until
    /// the first one is added. Read through `materialList`. The bytes live in the
    /// package's `Materials/` folder, not here — see `LectureDocument`.
    var materials: [CourseMaterial]?

    var materialList: [CourseMaterial] { materials ?? [] }

    init(
        name: String = "New Lecture",
        colorTag: String? = nil,
        needsSetup: Bool = true,
        sections: [LectureSection] = [],
        schedule: [ScheduleSlot] = [],
        sessions: [LectureSession] = []
    ) {
        self.name = name
        self.colorTag = colorTag
        self.needsSetup = needsSetup
        self.sections = sections
        self.schedule = schedule
        self.sessions = sessions
    }

    // MARK: Convenience queries

    func sections(sortedBySortOrder: Bool = true) -> [LectureSection] {
        sortedBySortOrder ? sections.sorted { $0.sortOrder < $1.sortOrder } : sections
    }

    func sessions(in section: LectureSection) -> [LectureSession] {
        sessions(inSectionWithID: section.id)
    }

    func sessions(inSectionWithID sectionID: UUID) -> [LectureSession] {
        sessions
            .filter { $0.sectionID == sectionID }
            .sorted { $0.date < $1.date }
    }

    func schedule(for section: LectureSection) -> [ScheduleSlot] {
        schedule.filter { $0.sectionID == section.id }
    }

    func section(withID id: UUID) -> LectureSection? {
        sections.first { $0.id == id }
    }

    /// Semester week the session falls in, if the lecture has a semester.
    func week(of session: LectureSession) -> Int? {
        semester?.week(of: session.date)
    }

    /// Weeks a material can be filed under: the semester's, plus any week that already
    /// holds one (the semester may have been shortened since).
    var materialWeekChoices: [Int] {
        let semesterWeeks = Set(1...max(semester?.weekCount ?? 0, 1))
        let used = Set(materialList.compactMap(\.week))
        return semesterWeeks.union(used).sorted()
    }

    // MARK: Session titles

    /// "W3 · Mon", "Assignment 3", or the date — whatever the session's section
    /// calls for. A custom `title` always wins.
    func title(for session: LectureSession, calendar: Calendar = .current) -> String {
        if let custom = session.title { return custom }
        let section = section(withID: session.sectionID)
        switch section?.naming ?? .weekly {
        case .numbered:
            let ordered = sessions(inSectionWithID: session.sectionID)
            let n = (ordered.firstIndex { $0.id == session.id } ?? 0) + 1
            return "\(section?.numberPrefix ?? "No.") \(n)"
        case .weekly:
            let day = Self.shortWeekday(of: session.date, calendar: calendar)
            guard let week = semester?.week(of: session.date, calendar: calendar) else {
                return "\(day) · \(LectureSession.dateFormatter.string(from: session.date))"
            }
            // Two meetings of one section on the same day ("Mon 10:00" and "Mon 14:00")
            // would otherwise get the same title.
            let sameDay = sessions.contains {
                $0.id != session.id && $0.sectionID == session.sectionID
                    && calendar.isDate($0.date, inSameDayAs: session.date)
            }
            let time = sameDay ? " " + Self.timeFormatter.string(from: session.date) : ""
            return "W\(week) · \(day)\(time)"
        }
    }

    /// Secondary line for lists: the date, when the title doesn't already show it.
    func subtitle(for session: LectureSession) -> String? {
        let naming = section(withID: session.sectionID)?.naming ?? .weekly
        let datedTitle = naming == .weekly && semester?.week(of: session.date) == nil
        return (datedTitle && session.title == nil)
            ? nil : LectureSession.dateFormatter.string(from: session.date)
    }

    private static func shortWeekday(of date: Date, calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let i = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(i) ? symbols[i] : "?"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Routine → sessions

    /// Removes a session, and remembers its meeting so `generateSessions()` doesn't
    /// create it again. The session's page data is not touched here — that is
    /// `LectureDocument.deleteSession(withID:)`'s job.
    mutating func removeSession(withID id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        skippedMeetings =
            (skippedMeetings ?? []) + [SkippedMeeting(sectionID: session.sectionID, date: session.date)]
    }

    /// Creates one session per occurrence of every schedule slot within the semester,
    /// skipping occurrences that already have a session, or whose session was deleted
    /// (`skippedMeetings`). Additive only: it never removes or moves a session, so it
    /// is safe to run again after the schedule or the semester changes. Returns how
    /// many sessions it added.
    @discardableResult
    mutating func generateSessions(calendar: Calendar = .current) -> Int {
        guard let semester else { return 0 }
        let first = calendar.startOfDay(for: semester.startDate)
        let last = Semester.endOfDay(semester.endDate, calendar: calendar)
        guard first < last else { return 0 }

        var added = 0
        for slot in schedule {
            // With one slot on this weekday, any session that day is "the" meeting —
            // including one the user added by hand. With several, match the time too.
            let sharesDay =
                schedule.filter { $0.sectionID == slot.sectionID && $0.weekday == slot.weekday }
                .count > 1
            var comps = DateComponents()
            comps.weekday = slot.weekday
            comps.hour = slot.startHour
            comps.minute = slot.startMinute
            var cursor = first.addingTimeInterval(-1)
            while let date = calendar.nextDate(
                after: cursor, matching: comps, matchingPolicy: .nextTime),
                date < last
            {
                cursor = date
                func isThisMeeting(sectionID: UUID, at other: Date) -> Bool {
                    guard sectionID == slot.sectionID,
                        calendar.isDate(other, inSameDayAs: date)
                    else { return false }
                    guard sharesDay else { return true }
                    let hm = calendar.dateComponents([.hour, .minute], from: other)
                    return hm.hour == slot.startHour && hm.minute == slot.startMinute
                }
                let exists =
                    sessions.contains { isThisMeeting(sectionID: $0.sectionID, at: $0.date) }
                    || (skippedMeetings ?? []).contains {
                        isThisMeeting(sectionID: $0.sectionID, at: $0.date)
                    }
                if !exists {
                    sessions.append(LectureSession(sectionID: slot.sectionID, date: date))
                    added += 1
                }
            }
        }
        return added
    }

    /// All page IDs across every session — used by `LectureDocument` to prune
    /// orphaned page/thumbnail data (e.g. after a session is deleted).
    var allPageIDs: Set<UUID> {
        Set(sessions.flatMap(\.pageIDs))
    }
}

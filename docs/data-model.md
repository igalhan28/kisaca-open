# Data model

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

Everything for one lecture lives in one `LectureManifest` (Codable), persisted as `manifest.json`
inside the document package. See `Models/LectureModels.swift` for the authoritative definitions.

```
LectureManifest
├─ name: String                        // "Calculus II"
├─ colorTag: String?                   // optional accent color name
├─ needsSetup: Bool                    // true until the user finishes LectureSetupView once
├─ semester: Semester?                 // startDate, endDate — absent in pre-2026-09-24 files
├─ sections: [LectureSection]          // "Lectures", "Exercise Sessions", "Labs", "Assignments", + custom
│   ├─ id, name, symbolName, sortOrder
│   ├─ naming: SessionNaming           // .weekly ("W3 · Mon") or .numbered ("Assignment 3")
│   └─ numberPrefix: String            // "Assignment" — the word before the number
├─ schedule: [ScheduleSlot]            // weekly meeting times; several per section allowed
│   ├─ id, sectionID, weekday (1=Sun...7=Sat), startHour/Minute, endHour/Minute
└─ sessions: [LectureSession]          // one per dated notebook
    ├─ id, sectionID, date, title?, pageIDs: [UUID], createdAt
```

## Routines: semester, naming, generated sessions (2026-09-24)

The app is meant as a student's hub for a course, so a lecture has a **routine**: the semester's
dates, and per section its weekly meeting times (Lectures on Monday *and* Thursday) and how its
sessions are named. It is set while creating the lecture and edited later from the calendar
button on the lecture's home screen — both use `Forms/RoutineEditor.swift`.

- **Weeks.** `Semester.week(of:)`: week 1 is the calendar week containing `startDate` (the user's
  calendar, Monday-first in most locales); a date after `endDate` or before week 1 has no week.
- **Titles are computed, never stored** — `LectureManifest.title(for:)`. A custom
  `LectureSession.title` wins; otherwise `.weekly` gives "W3 · Mon" (plus the time if the section
  meets twice that day) or, with no semester, "Mon · 21.09.2026"; `.numbered` gives
  "\(numberPrefix) \(n)" with `n` the session's position in date order. Changing the semester
  therefore renumbers everything consistently, and a make-up session added by hand slots in.
- **Generation** — `LectureManifest.generateSessions()` adds one session per slot occurrence in
  the semester, skipping days that already have one (matching the time too when the section meets
  more than once that weekday), so a session the user made by hand isn't duplicated. It is
  **additive only**: re-running after a change adds what's missing and never deletes or moves a
  session, because a session may already hold notes. Generated sessions have one page ID and no
  page data until drawn on — they cost a few bytes of manifest each.
- **Old files** decode unchanged: `semester` is optional, and `LectureSection` decodes a missing
  `naming` as `.numbered` for the old "Assignments" section (its `checklist` symbol) and `.weekly`
  otherwise, with `numberPrefix` derived from the name ("Assignments" → "Assignment").

Verified by compiling `LectureModels.swift` into a scratch executable (week numbering across a
Thursday semester start, Mon+Thu generation incl. a hand-made session on a meeting day, idempotent
re-run, old-manifest decoding, round-trip) and in the simulator through the routine sheet.

## Whole-section notebook

`PageRepository.Scope` is `.session(id)` or `.section(id)`. The section scope reads the section's
sessions back to back as one notebook ("all of the course's lecture notes"): every session up to
today, plus later ones that already have ink — the semester's empty future meetings are left out.
That session list is **frozen when the notebook opens**, because the scroll view addresses pages
by index and only an append at the end is safe; "next page" past the end appends to the last
session. It opens at the latest session (`NotebookScrollViewController.initialPageIndex`), and the
title follows the page being read ("Lectures · W3 · Mon", `NotebookCoordinator.currentSessionTitle`).
Ink drawn there lands in the owning session — verified in the simulator.

Recommended default sections (offered, not forced, at lecture creation): **Lectures, Exercise
Sessions, Labs, Assignments** — see `LectureSection.recommendedDefaults` in the models file.

A `LectureSession` is the notebook itself: `pageIDs` is the ordered list of A4 pages, exactly like
`Delve`'s single notebook used to be — the difference is a lecture document now holds *many*
independent page lists (one per session) instead of exactly one.

# Key decisions & rationale (condensed)

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

- **One document per lecture**, not one document for the whole app. Matches the user's own
  boilerplate choice (`DocumentGroup`), gives free iCloud Drive sync/sharing per-course, and
  matches how students actually think ("open my Calculus II file").
- **`ReferenceFileDocument`, not `FileDocument`.** See [document-format.md → Autosave design](document-format.md) — a value-type
  document holding potentially many megabytes of ink data across many pages would mean SwiftUI
  copies/diffs the whole thing on every edit; the reference + snapshot model avoids that.
- **`LectureSession` renamed from a first draft called `NotebookSession`/bare `Section`** to avoid
  clashing with SwiftUI's own `Section` view and to keep "Section" (Lectures/Labs/etc., a category)
  clearly distinct from "Session" (one dated notebook instance inside a category).
- **Schedule is generative when there is a semester** (changed 2026-09-24; it used to be advisory
  only). With semester dates, every weekly meeting time becomes a session per week; without them,
  a meeting time only pre-fills the date of a session added by hand. Generation is additive only —
  see [data-model.md → Routines](data-model.md).
- **Everything defaults to `@MainActor`** (project build setting `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`, already set by the user's boilerplate) — matches how PaperKit types are declared.
  `LectureDocument`'s whole `ReferenceFileDocument` conformance (including
  `fileWrapper(snapshot:configuration:)`) is deliberately kept uniformly `@MainActor` rather than
  splitting pieces off as `nonisolated` — see [actor-isolation.md](actor-isolation.md) for why.
  The plain data types (`LectureModels.swift`, `LectureDocument.Snapshot`) are the one deliberate
  exception, explicitly marked `nonisolated` since they have no reason to inherit the MainActor
  default.

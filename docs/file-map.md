# File map (`kisaca/`, the app target)

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

Xcode 26's **file-system-synchronized groups** are used here (see `project.pbxproj` —
`PBXFileSystemSynchronizedRootGroup`), meaning **any file placed under `kisaca/` is
automatically part of the build** — there is no need to hand-edit `project.pbxproj` to add
Swift files. Only `Info.plist` is special-cased (build-setting reference, not compiled).

```
kisaca/
├─ Navigation/                  — UIKit shell (see [uikit-migration.md](uikit-migration.md))
│   ├─ AppDelegate.swift        — @main; the shared LectureLibrary; replaces windows saved by the SwiftUI app
│   ├─ SceneDelegate.swift      — one window: its AppCoordinator, files opened from Files
│   ├─ AppCoordinator.swift     — the window's UINavigationController; pushes screens; setup → home swap; closes lectures on return home
│   └─ Routes.swift             — NotebookRoute (one session / a whole section)
├─ Lecture/                    — one open lecture's screens (UIKit since 2026-09-29)
│   ├─ LectureFileSync.swift    — name ↔ file sync, iCloud conflicts, background save (was LectureScreen)
│   ├─ LectureHomeViewController.swift — Materials row, sections + each one's next session; renameable title
│   ├─ SectionSessionsViewController.swift — Whole Notebook row, sessions grouped by semester week
│   ├─ MaterialsViewController.swift — the lecture's files: import (Files / drop), list, search, rename, delete
│   ├─ CourseMaterial+Files.swift — material symbol/type, importing files, copying dropped files
│   ├─ MaterialPreview.swift    — full-screen viewers: PDFKit reader for PDFs, Quick Look for the rest; temp-file helper
│   └─ MaterialReadingPosition.swift — where each PDF was left (UserDefaults) + `ResumingPDFView`
├─ Library/
│   ├─ LectureLibrary.swift     — finds lectures (iCloud container + local), open/close/create/import/delete
│   ├─ LectureFile.swift        — the UIDocument behind an open lecture; owns its LectureDocument
│   ├─ LibraryViewController.swift — home screen: Upcoming / Last Sessions + a shelf per lecture
│   └─ SessionCardCell.swift    — session / placeholder cards, grid paper, thumbnail cache, lecture colours
├─ Info.plist                   — declares the com.igalhan.kisaca.lecture package UTType
├─ Models/
│   └─ LectureModels.swift      — LectureSection, ScheduleSlot, LectureSession, LectureManifest
├─ Document/
│   ├─ UTType+Kisaca.swift
│   ├─ LectureDocument.swift        — in-memory lecture model; `load(from:)`, `fileWrapper`, `markDirty()`, `host`
│   ├─ DocumentNaming.swift         — file-name ↔ lecture-name rules + coordinated on-disk rename
│   └─ DocumentConflictResolver.swift — asks which iCloud conflict version to keep
├─ Notebook/                    — see [notebook-canvas.md](notebook-canvas.md)
│   ├─ PageGeometry.swift              — shared A4 size constant
│   ├─ PageRepository.swift            — page list + markup/thumbnail I/O against LectureDocument
│   ├─ PageCanvasController.swift      — one page: PaperKit canvas filling the width, owns its scroll/zoom
│   ├─ NotebookPagerViewController.swift — page-curl pager (UIPageViewController): edge-zone, one-finger, 2× turns; hidden tool picker
│   ├─ NotebookCoordinator.swift       — observable state between the bar and the canvas + autosave timer
│   ├─ NotebookViewController.swift    — the note-taking screen: canvas child, sidebar + status strip, applet panels, export button, tool wheel, double-tap to hide (see [sidebar.md](sidebar.md))
│   ├─ NotebookToolbox.swift           — the tool in hand (kind, colours, widths, eraser, ruler); device-local
│   ├─ ToolRailView.swift              — the black sidebar (back, applet buttons, scrolling tools, undo/redo) + `ToolControls` + `NotebookToolAction`
│   ├─ ToolIcons.swift                 — drawn tool pictures (pen, fountain pen, pencil, fineliner, highlighter, eraser, lasso)
│   ├─ ToolWheelView.swift             — the click-wheel tool switcher (two-finger sideways swipe) + `TwoFingerSwipeRecognizer`
│   ├─ PageThumbnailsViewController.swift — the Pages applet: thumbnails grouped by session, jump, add page
│   ├─ MaterialPaneViewController.swift — a material beside the notebook (PDFKit / embedded Quick Look)
│   └─ PDFExportViewController.swift   — "All Pages" vs "Select Pages" (thumbnail grid + checkmarks)
├─ Settings/
│   └─ AppPreferences.swift     — device-local preferences (UserDefaults keys + defaults), e.g. material pane side/width
├─ Utils/
│   ├─ GridBackground.swift     — the on-screen grid: one pixel-snapped layer per line
│   ├─ HexColor.swift           — `UIColor(hex:)` from a 24-bit integer
│   ├─ PageRenderer.swift       — off-screen ink-only render + vector grid (PDF, thumbnails)
│   └─ PDFExporter.swift        — exports a full session or an explicit page-index subset
└─ Forms/                       — the only SwiftUI left: forms, each hosted in a UIHostingController
    ├─ LectureSetupView.swift      — new lecture: name, sections, routine (pushed by AppCoordinator)
    ├─ RoutineEditor.swift         — semester + meeting times + naming form (setup and RoutineSheet)
    ├─ AddSessionSheet.swift       — "New Session" date form (SectionSessionsViewController)
    └─ LibrarySettingsView.swift   — storage location, move to iCloud, material pane side (LibraryViewController)
```

> **2026-09-28:** lectures now always live in the app's own folders ([library.md](library.md)), so
> renaming is a plain coordinated move again; the `UIDocumentBrowserViewController.renameDocument`
> workaround described below was removed. The history is kept for context.

# Naming: one lecture name

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

A user sees two names for the same thing: the **file name** (`Calculus II.kisaca`, in the
document browser and Files) and the **lecture name** (`LectureManifest.name`, the navigation
title). They must always be equal. **The file name is the truth** — it is what the browser shows and
what can be renamed from outside the app — so the lecture name always follows it, never the other
way round.

**File → lecture** (`LectureFileSync.reconcileNameWithFile()`; was `LectureScreen`). Runs on open, when the scene becomes
active again, when SwiftUI's `fileURL` changes, and on every `UIDocument.stateChangedNotification`
(a file move ends with one, and by then `fileURL` is the new URL; `.editingDisabled` marks a move
still in progress and is skipped). It is skipped while `needsSetup` is true — a placeholder
"Untitled" must never become the lecture's name — and while an in-app rename is in flight. A
document whose stored name went stale therefore heals itself the next time it is opened.

**Lecture → file** (`LectureFileSync.applyLectureName`; was `LectureScreen`). The setup form's "Create" and the title
menu's "Rename" (a `Binding<String>` on `.navigationTitle`) are the same code path. It sets
`manifest.name` to what was typed straight away (so the title never lags), saves the document
(`UIDocument.autosave()`), renames the file with the **system's** rename —
`UIDocumentBrowserViewController.renameDocument(at:proposedName:)`, on a throwaway browser instance —
then sets `manifest.name` to the name the file *actually* ended up with (illegal characters
replaced, " 2" on a collision). If the rename fails the name falls back to the file's real name
instead of staying different from it. `DocumentNaming.renameDocument` (a direct
`NSFileCoordinator` + `FileManager` move) is now only a fallback for when the system rename returns
nothing; it can only succeed for documents inside the app's own container.

**Where the current URL comes from.** `LectureDocument.liveFileURL`, i.e. the live `UIDocument`'s
`fileURL` (the `LectureFile` itself — formerly found by `DocumentHost.swift`) — **not** SwiftUI's `configuration.fileURL`,
which is captured once and never updated after a rename.

## What was wrong (2026-09-23, each reproduced — 1–4 in the simulator, 5 on a real iPad — then fixed)

1. **Stale URL.** Renaming twice in one session moved a file that no longer existed ("couldn't be
   moved … doesn't exist"), but `manifest.name` had already changed — title "Denny 7", file
   "Kinda". Fixed by using `liveFileURL`.
2. **Double commit.** SwiftUI's renameable title calls its binding setter twice per rename, which
   started two concurrent moves. Fixed by the `renamingTo` in-flight guard.
3. **The system's own Rename.** On a document created in the current session the title menu shows
   a file header plus a "Rename" that belongs to UIKit, not to us: it renames the file directly
   and never calls `applyLectureName`, and `fileURL` doesn't change — so the app title kept the old
   name ("Dyn A" title, `Dyn B.kisaca` file). Fixed by reconciling on `stateChangedNotification`.
4. **The name was never saved.** Manifest edits didn't mark the document dirty (see
   [document-format.md → Autosave design](document-format.md)), so a lecture set up and named but not drawn on reopened as a fresh
   setup screen while its file already carried the new name. Fixed by `markDirty()`.
5. **Renaming never worked on a real iPad** (found on the user's iPad Air M3, iOS 27, 2026-09-23 —
   the simulator can't show it). Both "Create" and "Rename" snapped back to "Untitled". Device log:
   `NSCocoaErrorDomain 513 "“Untitled 3” couldn’t be moved because you don’t have permission to
   access “DELVE”"`. Documents the user keeps in Files ("On My iPad/<folder>" or iCloud Drive) are
   outside the app's sandbox; the app is granted access to the *file*, not its *folder*, and a
   rename writes to the folder. The simulator keeps documents in the app's own container, which is
   why this passed every simulator test. Renaming from Files always worked because Files has that
   access. **Fix:** rename through `UIDocumentBrowserViewController.renameDocument(at:proposedName:)`,
   which runs with the system's access. Verified on the device: file renamed, name kept.
   Tried first and **did not work**: calling `UIDocument`'s `UINavigationItemRenameDelegate`
   `didEndRenamingWithTitle` directly — no error, the file just didn't move.

   **Expected side effect, not a bug:** right after an out-of-sandbox rename the open `UIDocument`
   can't get access to its new URL (`sandbox_extension_issue_file failed … Operation not permitted`
   in the log) and briefly reports `.closed | .savingError | .editingDisabled` (13). The system
   then reopens it at the new URL by itself — `configuration.fileURL` updates and the state goes
   back to normal, so a second rename in the same session works (verified 3× on the device). That
   is why `applyLectureName` saves *before* renaming: anything unsaved at that moment would not
   survive the reopen. Don't add code that reacts to that transient state (an attempt that
   dismissed back to the browser on `.closed` was removed — the system's reopen already handles it).

## Known limitation (cosmetic, not fixed)

On a document created in the current session, the small header at the top of the system title
menu (file icon + name + share button) keeps showing the placeholder name ("Untitled 3") until
the document is reopened. UIKit builds it once at creation. Setting `navigationItem.title` on the
document's navigation item after the move does not change it, and `documentProperties` is `nil`
there, so there is nothing public to refresh. The file name, the document browser and the app's
own title are all correct; reopened documents don't show this header at all.

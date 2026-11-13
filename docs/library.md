# Library & home screen

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

Since 2026-09-28 the app no longer uses `DocumentGroup`. Its launch screen was the system document
browser (the user found that a "Files app" home screen got in the way), and documents opened from
anywhere in Files were only reachable through security-scoped URLs — the cause of the rename EPERM
(513) on real iPads ([naming.md](naming.md)) and of friends' "can't open" reports (plain
`Data(contentsOf:)` reads of package contents / picked files outside the sandbox, no coordination).

## Where lectures live

`Library/LectureLibrary.swift`. Lectures are always in the app's **own** folders:

| Folder | When | Shown in Files as |
|---|---|---|
| ubiquity container `iCloud.com.igalhan.kisaca` → `Documents/` | iCloud Drive available to the app | `iCloud Drive › KISACA` |
| app `Documents/` | always (fallback; also old lectures created there by DocumentGroup) | `On My iPad › KISACA` |

Both are listed together. New lectures go to iCloud when available. Settings has **Move … to
iCloud** (`FileManager.setUbiquitous`) for the local ones; the home screen marks them with
`icloud.slash`. No iCloud (signed out / iCloud Drive off / full): everything still works locally;
when full, files save locally and upload later.

- iCloud files are found with `NSMetadataQuery` (the only way to see not-yet-downloaded items and
  hear about other devices' changes). Not-downloaded items get `startDownloadingUbiquitousItem`
  and show a "Downloading" placeholder card.
- Local files: a plain directory scan on start, on `scenePhase == .active`, after every library op.
- The home screen reads only `manifest.json` (coordinated, off the main actor) and, per card,
  `Thumbnails/<first page>.ink.png`.
- **Import** (home toolbar, and `.onOpenURL` for a `.kisaca` tapped in Files / sent from another
  app) **copies** the file into the library with a coordinated read — which also downloads files
  that are only in the cloud. Originals are left where they were (the user's old
  `iCloud Drive/ETHSAL/ kısaca/` files have to be imported once).
- Entitlements: `kisaca.entitlements` (repo root) (CloudDocuments + container); Info.plist has
  `NSUbiquitousContainers` (public, name KISACA), `LSSupportsOpeningDocumentsInPlace`,
  `UIFileSharingEnabled`. `UISupportsDocumentBrowser` was removed.

## Opening a lecture

`Library/LectureFile.swift` — a `UIDocument` subclass owning the `LectureDocument` model.
`load(fromContents:)` → `LectureDocument.load(from:)` (full reset; also runs when iCloud brings a
newer version), `contents(forType:)` → `fileWrapper(snapshot:existingFile:)` with the last
loaded/saved wrapper as `existingFile`. `UIDocument` is not MainActor-isolated, so both hop to the
main actor (in place when already on main — UIKit's normal case).

`Navigation/AppCoordinator.swift` (one per window; UIKit since 2026-09-28 —
[uikit-migration.md](uikit-migration.md)) owns the window's `UINavigationController`. A lecture is
opened **before** it is pushed (`LectureLibrary.open`), and the pushed screens hold the
`OpenLecture` itself. Once the home screen is showing again every open lecture is saved and closed
(`closeAll`, from `navigationController(_:didShow:)` — completed transitions only, so a cancelled
swipe-back closes nothing). A session card sets the stack to home → lecture → notebook, so Back
goes notebook → lecture → home. A `.kisaca` opened from Files arrives in
`SceneDelegate.scene(_:openURLContexts:)` (or the launch options, after the library has started).

`Lecture/LectureFileSync.swift` (was `Views/LectureScreen.swift`, before that `ContentView`) keeps the
name sync, one per open lecture, kept by `AppCoordinator` and shared by the setup form and the
lecture's home screen; renaming is a plain coordinated move (`DocumentNaming.renameDocument`) —
allowed because the file is in our folder. `DocumentConflictResolver` is called by `LectureFileSync`
when the lecture opens and on every state change.

## Home screen

`Library/LibraryViewController.swift`, `Library/SessionCardCell.swift` (UIKit since 2026-09-30; were
`LibraryHomeView` / `SessionCard`) — from the user's sketch:
**Upcoming Sessions** (today onwards, all lectures), **Last Sessions** (before today, newest
first), then one shelf per lecture (opens scrolled to its session nearest today). Cards: top of the
first page (grid + ink thumbnail, always light paper), section symbol badge, "Today" chip, lecture ·
section, title · date. Lecture colour = stable hash of the name (`LectureColor`). Header tap opens
the lecture; long-press → Open / Delete. Toolbar: Settings, Import, New Lecture.

## Verified (simulator, 2026-09-28)

The iPad Pro 11" (M5) simulator is signed in to iCloud, so the ubiquity container works there
(`…/data/Library/Mobile Documents/iCloud~com~igalhan~kisaca/Documents`). Checked: listing local +
iCloud, thumbnails, session card → notebook, back → saved + closed (thumbnail on disk), New Lecture
→ setup → file renamed in iCloud, Move to iCloud, Delete. **Not yet:** Import through the picker,
`.onOpenURL`, a real device, two devices syncing.

## Deleting a lecture

`LectureLibrary.delete` removes the file with a coordinated delete, then forgets it in the entries
**and in the last scan results** (`iCloudFound` / `localFound`) before refreshing. Without the
latter (fixed 2026-09-30), the refresh rebuilt the list from the iCloud query's stale results — it
hadn't reported the deletion yet — so the lecture came straight back as "This file couldn't be
read." until the next launch.

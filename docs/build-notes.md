# Build notes

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

- Xcode 26.2 / iOS 26 SDK confirmed available in this environment (`xcodebuild -version`).
- **Before touching isolation on `LectureDocument` or `LectureFile`**, read
  [actor-isolation.md](actor-isolation.md) in full.
- The project uses file-system-synchronized groups — adding/removing `.swift` files under
  `kisaca/` (the app target, inside this repo) is enough; no `project.pbxproj` surgery needed for source files.
- PaperKit requires a **real iOS 26 target** (simulator is fine for compiling/UI flow, but Apple
  Pencil input obviously requires a physical iPad to actually test drawing).
- To build from the command line:
  ```
  xcodebuild -scheme kisaca -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
  ```
- If you hit a build error after a context refresh: re-read `ARCHITECTURE.md`'s Status section first to
  see what was mid-flight, then check the actual compiler error — don't assume the architecture
  described here is wrong before checking whether the code just hasn't caught up to it yet.

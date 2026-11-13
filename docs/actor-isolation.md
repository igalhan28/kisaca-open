> **2026-09-28:** `DocumentGroup` and the `ReferenceFileDocument` conformance are gone ([library.md](library.md)).
> `LectureDocument` stays `@MainActor`; `LectureFile` (a nonisolated `UIDocument`) hops to the main
> actor in `load(fromContents:)` / `contents(forType:)` — in place on the main thread, otherwise with a
> real `DispatchQueue.main.sync`, never a bare `assumeIsolated` (lesson 2 below).
>
> **Later on 2026-09-28 (UIKit migration step 0.2):** `LectureDocument` is now `@MainActor @Observable`,
> no longer `ObservableObject`/`@Published` ([document-format.md → Autosave design](document-format.md)).
> The `@Published`/`Sendable` constraints in the saga below came from `ReferenceFileDocument` and no
> longer apply; the `@MainActor` isolation and the `LectureFile` hop are unchanged.

# Actor isolation (`LectureDocument` / `kisacaApp`)

> Part of the architecture docs — start at [ARCHITECTURE.md](../ARCHITECTURE.md).

**Actor isolation saga (resolved — for real this time; two earlier "fixes" here each
introduced a new problem, so read this fully before touching isolation on `LectureDocument`
or `kisacaApp.swift` again):**
1. `LectureDocument.init(configuration:)` was first written `nonisolated` (the
   textbook-correct choice for background-thread document reading). Doesn't compile:
   `@Published var manifest` synthesizes an isolated `_enclosingInstance` subscript (needed to
   fire `objectWillChange` safely) that only exists on the main actor, so assigning
   `self.manifest = ...` from a `nonisolated init` fails with "main actor-isolated property
   'manifest' can not be mutated from a nonisolated context." **Confirmed by an actual compile
   error, not theory.**
2. Fix attempt #1: make the whole `ReferenceFileDocument` conformance uniformly `@MainActor`
   (`init(configuration:)`, `snapshot`, `fileWrapper` all MainActor, nothing `nonisolated`).
   This compiled, with one warning ("conformance ... crosses into main actor-isolated code —
   this is an error in the Swift 6 language mode"). To make the `DocumentGroup(newDocument:)`
   closure compile against this MainActor-isolated init, `kisacaApp.swift` used
   `MainActor.assumeIsolated { LectureDocument() }`. **This was wrong, and not just a lingering
   warning — it crashed with `EXC_BREAKPOINT` the first time a user actually tapped "Create
   Document."** `assumeIsolated` is a *runtime assertion* ("I am definitely already on
   MainActor"), not a hop — and the assertion was false. Confirmed against SwiftUI's actual
   `swiftinterface`: `DocumentGroup(newDocument:)`'s real signature is
   `@Sendable () -> Document`, explicitly documented-by-type-signature to be callable from any
   thread, and it does call it off the main thread in practice, not just in theory.
3. Fix attempt #2: make `LectureDocument` `nonisolated` entirely, on the theory that a fully
   nonisolated class needs no hop at all. **Also wrong**, for a different reason: SwiftUI's
   `swiftinterface` also shows `protocol ReferenceFileDocument: ObservableObject, Sendable` —
   `Sendable` is a hard requirement. A class with mutable stored properties (`manifest`,
   `pageData`, `thumbnailData`) can't satisfy `Sendable` safely while `nonisolated`; making it
   so surfaced *new* warnings ("stored property '_manifest' ... is mutable" on a
   Sendable-conforming class, and "`nonisolated` is not supported on properties with property
   wrappers — this is an error in the Swift 6 language mode" on `@Published var manifest`).
   `@MainActor` is the standard, Apple-sanctioned way a class with mutable state satisfies
   `Sendable` (serialized access through one actor), and `ReferenceFileDocumentConfiguration`
   itself is declared `@MainActor` in SwiftUI — the framework is built around this type being
   MainActor-isolated, not nonisolated.
4. **The actual fix**: keep `LectureDocument` `@MainActor` (back to state #2's type, warning
   included — it's accepted, see the long comment on the class declaration for the full
   reasoning). Fix only the real problem, which was never the class's isolation — it was that
   `kisacaApp.swift`'s `newDocument` closure asserted an isolation context instead of actually
   establishing one. It now performs a genuine hop:
   `Thread.isMainThread ? MainActor.assumeIsolated { LectureDocument() } :
   DispatchQueue.main.sync { MainActor.assumeIsolated { LectureDocument() } }` — checking
   `Thread.isMainThread` first avoids a self-deadlock if the closure happens to already be on
   the main thread; `DispatchQueue.main.sync` performs a *real* synchronous hop otherwise, so
   `assumeIsolated`'s assertion is actually true by the time it runs. `init(configuration:)`
   and `fileWrapper(snapshot:configuration:)` don't need this treatment even though they're
   also MainActor-isolated witnesses for nonisolated protocol requirements — they're
   conformance witnesses, not a closure handed to a `@Sendable`-typed parameter, so Swift's
   "isolated conformances" feature (`-enable-upcoming-feature InferIsolatedConformances`,
   already on for this project) makes the framework's generic calls into them hop
   automatically. A plain closure literal gets no such help, which is exactly why
   `newDocument` needed the manual, real hop and nothing else did.

**The one remaining, accepted warning** ("conformance ... crosses into main actor-isolated
code") is inherent to state #2/#4's trade-off and is not a sign anything is still broken —
see the long comment on `class LectureDocument` for why it's accepted rather than chased
further. Reading/writing a manifest + raw page bytes on the main actor is cheap enough for
MVP; if a lecture ever gets large enough for this to visibly stall document-open or save,
revisit by dropping `@Published` in favor of a plain `var manifest` + manual
`objectWillChange.send()` calls at every mutation site (more error-prone, so deliberately not
done preemptively). Separately, `LectureModels.swift`'s types (`LectureSection`,
`ScheduleSlot`, `LectureSession`, `LectureManifest`) and `LectureDocument.Snapshot` remain
explicitly marked `nonisolated` — they're plain data with no reason to inherit the project's
MainActor default, and this part was never in question.
**General lesson, not just for this file:** when a warning fix compiles, that is necessary but
not sufficient — an isolation assumption (`assumeIsolated`, or reasoning about "this probably
only runs on the main thread") needs to be checked against the actual documented behavior of
the API involved (here, by reading the real framework interface, not by assuming) before
trusting it, because the compiler will not catch a *wrong* assumption, only a missing one.

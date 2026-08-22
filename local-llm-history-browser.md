# Local LLM History Browser — Execution Plan

A read-only "Explore Logs" browser for the LM Studio / oMLX log files that are
already scan/purge/search-eligible in the **Local AI Storage** panel. Lets the
user pick a log target, browse its files (month-sectioned for `server-logs`),
and read any file's contents with a tail-first large-file strategy.

---

## Summary

**Purpose / goal.** Add a fourth capability to the Local AI Storage panel —
*Explore logs* — sitting alongside the existing *Search retained text…* and
*Purge…* actions. The browser is strictly **read-only**: it lists files under
the explorable targets and renders a chosen file's text, with nothing written
or deleted. It complements, and is deliberately distinct from, the two
existing sheets:

- **Search** (`AIStorageSearchSheet`) answers *"is my secret in here?"* and
  therefore reports **paths + match counts only**, never the matched text.
- **Explore** (this feature) is *"let me read this specific file I chose."*
  Rendering that file's own contents is the entire point.
- **Purge** (`AIStoragePurgeSheet`) deletes, and stays isolated in its own
  sheet so its "destructive control must not move under the pointer" invariant
  is untouched.

**Key objectives.**

- Browse the three text-bearing log targets: `~/.lmstudio/server-logs`,
  `~/.lmstudio/conversations`, and `~/.omlx/logs`. (Binary oMLX cache / vision
  feature targets are excluded — meaningless as text.)
- Handle the real data shape on this machine: `server-logs` is **~29 GB /
  ~3080 `.log` files**, month-subdirectored (`YYYY-MM/`), daily logs rotated at
  **~10 MB** each (`YYYY-MM-DD.NN.log`). A flat list is unusable at that scale;
  the browser must section by month and render the **tail** of large files.
- Keep every new filesystem routine **root-guarded** (read-only analog of the
  existing `isPurgeable` symlink-resolve-under-`~/.lmstudio|~/.omlx` check) and
  make it **unit-testable** without touching the real home directory.
- Follow the project's existing testing idiom (`@testable import` + pure
  static-helper `XCTest` cases) — the suite already exists.

**Critical success factors.**

- No whole-file memory blowup on the 10 MB logs (map + tail-slice, lossy UTF-8).
- The 3080-row file list stays responsive (virtualized, newest-first, filtered).
- Zero writes / zero deletes from the browser; the search and purge sheets are
  behaviorally unchanged.
- `swift test` is green at every testing milestone (incremental, not
  end-of-project).

**Defaults applied** (override any of these if you disagree):

- **Testing strategy:** incremental / iterative — a dedicated testing milestone
  runs after each worker milestone (T1, T2, T3, T4).
- **Testing modes:** automated-first. This is a native macOS SwiftUI app (no
  web / no Playwright), so automated verification is **SPM `XCTest`**
  (unit + filesystem-integration against a temp root). UI visual sign-off is
  **screenshot review** rendered via SwiftUI's `ImageRenderer` (the
  native-app analog of framework snapshot tooling) with PNGs dropped into
  `docs/screenshots/` for inline review. **Hands-on** testing is reserved for
  the live 29 GB browsing workflow that fixtures cannot capture.
- **Scope:** the **three log targets only** (`server-logs`, `conversations`,
  `omlx.logs`). Extending to the other purge-eligible text targets
  (`user-files`, `parsed-documents-cache`, `RAG chunks`, etc.) is a one-flag
  change and is deferred, not in scope.
- **Sheet geometry:** **~820 pt wide**, two-column (file list | viewer),
  wider than the 560 pt search/purge sheets, because list + monospaced viewer
  do not fit side-by-side at 560.
- **Large-file policy:** render the **tail** (~256 KB) first, scroll to bottom,
  with an explicit *Load full file* action.
- **Testability:** `AIStorageCollector` gains an injectable root (defaulting to
  the real home) so integration tests plant a fake tree under a temp dir.
- **No database schema** is created or modified by this feature, so the spec's
  *Schema Review Milestone* is intentionally **omitted**.

---

## Milestone Progress Tracker

| Milestone | Model | Status | Duration (min) | Notes |
|---|---|---|---|---|
| M1 — Data model & testable helpers | Sonnet | ✅ Done | 7 | `AIStorageFileEntry`, `isExplorable`, pure helpers, preview fixture |
| T1 — Pure-helper unit tests | Sonnet | ✅ Done | 10 | month-section, root-guard, tail-slice |
| M2 — Collector file-system APIs | Sonnet | ✅ Done | 9 | injectable root, `listFiles`, `readTail`/`readFull`, `explorableTargets` |
| T2 — Filesystem integration tests | Sonnet | ✅ Done | 12 | temp-tree listing/order/sectioning, tail correctness, guard denial |
| M3 — Log browser UI + panel entry point | Opus | ✅ Done | 11 | `AIStorageLogsSheet`, viewer, panel button, model wrappers |
| T3 — Screenshot review + hands-on browsing | — | ⬛ Skipped (user) | — | User tests visuals manually |
| M4 — Polish, edge cases & accessibility | Opus | ✅ Done | 16 | scroll-to-bottom, paging, cancellation, a11y, dark/light |
| T4 — Regression (automated only) | orchestrator | ✅ Done | 2 | full `swift test` green, Search/Purge unchanged; screenshots/hands-on dropped |

*Model guidance:* Haiku = mechanical/boilerplate; Sonnet = most feature work
and well-defined tasks; Opus = complex architecture **and all front-end UI
design work** (M3/M4/T3 are UI and are pinned to Opus accordingly).

---

## Table of Contents

- [Summary](#summary)
- [Milestone Progress Tracker](#milestone-progress-tracker)
- [Milestone 1 — Data model & testable helpers](#milestone-1--data-model--testable-helpers)
- [Testing Milestone T1 — Pure-helper unit tests](#testing-milestone-t1--pure-helper-unit-tests)
- [Milestone 2 — Collector file-system APIs](#milestone-2--collector-file-system-apis)
- [Testing Milestone T2 — Filesystem integration tests](#testing-milestone-t2--filesystem-integration-tests)
- [Milestone 3 — Log browser UI + panel entry point](#milestone-3--log-browser-ui--panel-entry-point)
- [Testing Milestone T3 — Screenshot review + hands-on browsing](#testing-milestone-t3--screenshot-review--hands-on-browsing)
- [Milestone 4 — Polish, edge cases & accessibility](#milestone-4--polish-edge-cases--accessibility)
- [Testing Milestone T4 — Regression & final sign-off](#testing-milestone-t4--regression--final-sign-off)
- [Parallel Development Recommendations](#parallel-development-recommendations)
- [Gap-Filling Prompt Requirements](#gap-filling-prompt-requirements)
- [Progress Log / Notes](#progress-log--notes)

---

## Milestone 1 — Data model & testable helpers

**Recommended model:** Sonnet.

Introduce the data types the browser needs and extract the logic that will be
unit-tested into pure, filesystem-free helpers — mirroring the existing
`ProcessSearchFilter.apply` test idiom in `Tests/MacResourceMonitorTests`.

**Files touched:**

- `src/Models/SystemMetrics.swift` — new `AIStorageFileEntry`, `isExplorable`
  on `AIStorageTarget`, extended preview fixture.
- `src/Services/AIStorageCollector.swift` — `isExplorable` on `Spec`, and the
  pure static helpers below.
- `Tests/MacResourceMonitorTests/AIStorageLogLayoutTests.swift` (new, or fold
  into M2's test file if preferred) — test scaffolding for the helpers.

**Tasks.**

- [x] Add `struct AIStorageFileEntry: Identifiable, Hashable` to
  `SystemMetrics.swift` with: `id`, `name`, `path`, `displayPath`
  (`~`-abbreviated), `relativePath` (relative to the target dir), `sizeBytes`,
  `modifiedAt: Date`, `monthSection: String?` (`YYYY-MM`, non-nil only for
  `server-logs`), and `looksBinary: Bool` (extension-based heuristic:
  `.log`/`.txt`/`.json` → false; the oMLX cache/vision extensions → true).
- [x] Add `let isExplorable: Bool` to `AIStorageTarget` and to the collector's
  private `Spec`. Set `isExplorable = true` on exactly three specs:
  `lmstudio.server-logs`, `lmstudio.conversations`, `omlx.logs`. All others
  (including the binary `omlx.cache` / `omlx.vision-features`) stay `false`.
  Plumb the flag through `scan()` into the produced `AIStorageTarget`.
- [x] Add `var explorableTargets: [AIStorageTarget]` (and a
  `containsExplorable: Bool` convenience) to `AIStorageSnapshot`.
- [x] Extract pure static helpers (filesystem-free) for unit testing:
  - [x] `enum AIStorageLogLayout` with
    `static func monthSection(for date: Date) -> String` returning `YYYY-MM`
    (fixed-locale, no user locale leakage).
    - [x] `static func newestFirst(_ a: AIStorageFileEntry, _ b: AIStorageFileEntry) -> Bool`
      comparator (date desc, then name desc as tiebreak).
  - [x] `enum AIStoragePathGuard` with
    `static func isReadable(path: String, homePath: String) -> Bool` — the
    read-only analog of `isPurgeable`: `path` (already resolved) must be under
    `homePath + "/.lmstudio/"` or `homePath + "/.omlx/"`, and must not equal or
    be under any never-touch path (`.lmstudio/models`,
    `.lmstudio/.internal/bundled-models`, `.omlx/bin`, `.omlx/settings.json`).
  - [x] `enum AIStorageTailReader` with
    `static func sliceTail(_ data: Data, limit: Int) -> (text: String, totalBytes: Int, truncated: Bool)` —
    take the last `limit` bytes, **align up to the first newline** so the first
    visible line isn't a torn fragment, decode lossy UTF-8, and set
    `truncated = data.count > (bytes actually taken)`.
- [x] Extend the `#if DEBUG` `AIStorageSnapshot.preview` fixture: set
  `isExplorable` correctly on its targets, and add a
  `static let previewFileEntries: [AIStorageFileEntry]` (a handful of entries
  spanning two month sections, one small and one "large" with a realistic
  `sizeBytes`, and one `.json`) so the UI can be rendered deterministically.

> **Worker completion requirement:** complete **all** items above. Do not drop
> an item because it looks low-priority or slightly out of scope — if it is
> listed, do it. If you believe an item should be removed or deferred, still
> attempt it and note the reason in your summary for the orchestrator.

[Return to Top](#summary)

---

## Testing Milestone T1 — Pure-helper unit tests

**Recommended model:** Sonnet.
**Mode(s):** automated — SPM `XCTest` (unit). Baseline first, then new cases.

- [x] **Baseline:** run `swift test` and confirm the *existing* suite is green
  before adding anything (the repo already has 9 test files; the CLAUDE.md
  "no test suite yet" note is stale — do not scaffold a new target).
- [x] Write `AIStorageLogLayoutTests` (or extend the M1 file):
  - [x] `monthSection(for:)` maps a set of fixed dates to the expected
    `YYYY-MM`, including a year boundary (`2026-01-01` → `2026-01`,
    `2026-12-31` → `2026-12`) and is locale-independent.
  - [x] `newestFirst` orders date-desc and name-desc tiebreak as specified.
- [x] Write `AIStoragePathGuardTests` — an **accept/deny matrix**:
  - [x] accepts `~/.lmstudio/server-logs/2026-08/x.log`,
    `~/.omlx/logs/server.log`, a nested `~/.lmstudio/conversations/a.json`.
  - [x] denies a path outside both roots (`/tmp/...`, sibling dir).
  - [x] denies the never-touch paths and anything under them.
  - [x] denies the root dirs themselves (`.lmstudio` with nothing after it).
- [x] Write `AIStorageTailReaderTests`:
  - [x] small file (< limit) → `truncated == false`, full text preserved.
  - [x] large file (> limit) → `truncated == true`, `totalBytes == data.count`,
    returned text is the trailing content.
  - [x] first visible line is not torn (result starts at a newline boundary
    when the cut is mid-line).
  - [x] multi-byte / non-UTF8 byte at the cut boundary decodes lossy without
    throwing.
  - [x] empty data → empty text, `truncated == false`, `totalBytes == 0`.
- [x] Run `swift test`; **all cases green** before proceeding to M2.

> Every listed case must be written and passing. Report the final
> `swift test` pass/fail counts in your summary.

[Return to Top](#summary)

---

## Milestone 2 — Collector file-system APIs

**Recommended model:** Sonnet.

Add the filesystem-backed, root-guarded, read-only APIs the UI will call, and
make the collector's root injectable so M2's tests can run against a temp tree.

**Files touched:** `src/Services/AIStorageCollector.swift`,
`src/Services/AIStorageModel.swift` (thin `@MainActor` wrappers only — no UI
logic here).

**Tasks.**

- [x] Make the scan root injectable: `init(settings: OMLXSettings = .shared,
  root: URL? = nil)` where `root` defaults to
  `FileManager.default.homeDirectoryForCurrentUser`. All `url(for:)` / path
  resolution goes through this root so tests can point it at a temp dir. The
  real (production) init is unchanged in behavior.
- [x] Add `func listFiles(targetID: String) async throws -> [AIStorageFileEntry]`:
  - [x] Resolve the target's spec (must be `isExplorable`); if the directory
    does not exist, return `[]`.
  - [x] Recursive `FileManager.enumerator` walk (hidden files included — LM
    Studio hides plenty), producing one `AIStorageFileEntry` per regular file,
    populating `sizeBytes` (allocated size, same keys as `measure`),
    `modifiedAt`, `relativePath`, `displayPath`, and `monthSection`
    (`AIStorageLogLayout.monthSection` applied to `modifiedAt`, only for
    `lmstudio.server-logs`).
  - [x] **Root-guard every yielded path** through
    `AIStoragePathGuard.isReadable(path:homePath:)`; drop (do not crash on)
    any entry that resolves outside the allowed roots.
  - [x] Sort the result with `AIStorageLogLayout.newestFirst`.
  - [x] Check `Task.checkCancellation` on a stride (the walk is ~3000 files);
    throw `CancellationError` when cancelled.
  - [x] Never create, modify, or delete anything — read-only.
- [x] Add `func readTail(path: String, limit: Int = 256 * 1024) async ->
  (text: String, totalBytes: Int, truncated: Bool)`:
  - [x] Root-guard `path` before reading; on denial return
    `("", 0, false)` (or a distinguishable "denied" result — decide and keep it
    testable).
  - [x] `Data(contentsOf:options:[.mappedIfSafe])`; apply
    `AIStorageTailReader.sliceTail(_:limit:)`.
  - [x] If the file vanished between list and read, surface a clean
    "file no longer exists" outcome (not a crash).
- [x] Add `func readFull(path: String) async ->
  (text: String, totalBytes: Int)`:
  - [x] Root-guard, then mapped read + lossy UTF-8 of the **entire** file
    (bounded in practice by the ~10 MB rotation size; note in a comment that a
    single unbounded log is the accepted tradeoff for an explicit user action).
- [x] Add `var explorableTargets: [AIStorageTarget]` passthrough on
  `AIStorageModel`, plus `@MainActor` async wrappers:
  `listFiles(targetID:)`, `open(entry:)` (→ `readTail`), and
  `loadFull(entry:)` (→ `readFull`), returning a small
  `AIStorageFileContent` value (text, totalBytes, isTruncated, displayPath,
  looksBinary). Keep these thin — no UI concerns.

> **Worker completion requirement:** complete **all** items above. The
> production (no-`root`) path must behave exactly as the existing scan does.
> Note any item deferred in your summary.

[Return to Top](#summary)

---

## Testing Milestone T2 — Filesystem integration tests

**Recommended model:** Sonnet.
**Mode(s):** automated — SPM `XCTest` (filesystem integration against a temp
root via the injectable `root:` from M2).

- [x] In each test, create a **temp directory** as the fake root and plant a
  minimal realistic tree, e.g.
  `.lmstudio/server-logs/2026-08/2026-08-22.17.log`,
  `.lmstudio/server-logs/2026-07/2026-07-31.1.log`,
  `.lmstudio/conversations/1784921389195.conversation.json`,
  `.omlx/logs/server.log`, plus one **binary** file to exercise
  `looksBinary`. Clean up in `tearDown`.
- [x] `listFiles` tests:
  - [x] returns entries for a present target and `[]` for a missing one.
  - [x] ordering is newest-first (verify against planted mtimes — set them
    explicitly with `setAttributes(_:ofItemAtPath:)` so the test is
    deterministic).
  - [x] `monthSection` is populated and correct for `server-logs` entries and
    `nil` for `conversations` / `omlx.logs` entries.
  - [x] `sizeBytes` / `modifiedAt` / `relativePath` / `displayPath` are
    populated correctly.
  - [x] a planted file that resolves **outside** the allowed roots is dropped
    (e.g. a symlink escaping the root), not returned and not crashing.
  - [x] cancellation: cancelling the task mid-walk throws `CancellationError`.
- [x] `readTail` tests:
  - [x] small file → `truncated == false`, exact content.
  - [x] a file larger than `limit` (write > 256 KB) → `truncated == true`,
    `totalBytes` correct, text is the tail.
  - [x] a path outside the roots → the "denied" outcome, no read.
  - [x] a deleted/missing path → the clean "no longer exists" outcome.
- [x] `readFull` test: returns full content + correct `totalBytes` for a
  moderately large temp file.
- [x] Confirm **no mutation**: after a `listFiles`/`readTail`/`readFull` pass,
  the planted tree is byte-identical (hash or recursive compare) — the
  browser APIs are read-only.
- [x] Run `swift test`; **all cases green** before proceeding to M3.

> Write and pass **every** listed case. Report the final `swift test` counts in
> your summary.

[Return to Top](#summary)

---

## Milestone 3 — Log browser UI + panel entry point

**Recommended model:** **Opus** (front-end UI design work — mandatory per the
model guidelines; Sonnet consistently falls short on UI taste/polish).

Build `AIStorageLogsSheet` and wire it into the panel. Apply genuine
front-end design craft: this should feel like a native macOS log viewer, not
generic AI UI. Reference real patterns — **Console.app / Activity Monitor**
for the dense monospaced log view, **Finder** for the source/file list and
section headers, and the existing `AIStoragePanelView` material + typographic
scale (13/12/11/10 pt steps, SF Mono for log text) so it reads as a sibling,
not a foreign object.

**Files touched:** `src/Views/AIStorageLogsSheet.swift` (new),
`src/Views/AIStoragePanelView.swift` (new button + sheet presentation),
`src/Services/AIStorageModel.swift` (only if a wrapper from M2 needs a UI-
shaped tweak).

**Layout target (~820 pt wide, two-column):**

- Top: a segmented/inline **target `Picker`** over the existing + explorable
  targets (`Server logs | Conversations | oMLX logs`), with the panel's
  refresh affordance carried over (a small "re-list" that re-runs
  `listFiles` for the current target).
- Left (~280 pt): the **file list** — month-sectioned for `server-logs`
  (section headers like `2026-08`, sticky), newest-first, a **quick filter**
  (`All / 30 days / 7 days`), rendered in a `ScrollView` + `LazyVStack` so the
  3080-row case never renders all at once. Each row: name, size (SF Mono),
  relative path truncated-middle.
- Right (rest): the **viewer** — monospaced, tail-first, auto-scrolled to
  bottom on open; a banner line `showing last 256 KB of 10.5 MB` with a
  **Load full file** action when `truncated`; a **raw | pretty** toggle for
  `.json` (pretty = indent-parse when parseable, else raw); a
  **Reveal in Finder** action (`NSWorkspace.shared.activateFileViewerSelecting`);
  a **binary file** notice; and a **file no longer exists** state that offers
  to re-list.

**States to design (each must look intentional):** loading list, empty target
(no files), populated list + selected file, large-file tail banner, binary
notice, file-missing.

**Tasks.**

- [x] Create `AIStorageLogsSheet` with `@ObservedObject var model:
  AIStorageModel` and the two-column layout above; width ~820.
- [x] Target `Picker` bound to `model.explorableTargets` filtered to
  `exists`; selecting a target triggers `listFiles` (with a brief loading
  state; guard against duplicate in-flight lists).
- [x] File list: month-sectioned (when `monthSection != nil`) else single
  section; `LazyVStack`; `All / 30 days / 7 days` filter applied client-side to
  the already-sorted entries; row tap selects + opens.
- [x] Viewer: render `AIStorageFileContent.text` in SF Mono; auto-scroll to
  bottom on open; tail banner + *Load full file*; raw/pretty toggle for JSON;
  Reveal in Finder; binary notice; file-missing + re-list.
- [x] Add an **Explore logs…** button to `AIStoragePanelView.actions`, enabled
  only when `model.snapshot?.containsExplorable == true`, presenting
  `AIStorageLogsSheet` via a new `@State showingExplore`.
- [x] Ensure the browser **never mutates**: no delete/purge control anywhere in
  the sheet; the only filesystem write is the read path.
- [x] A `#Preview` using a fixture `AIStorageModel` seeded with
  `AIStorageSnapshot.preview` + `AIStorageSnapshot.previewFileEntries` (and a
  seeded selection + a "large" entry) so the populated, tail-banner, and
  empty states are all renderable for T3's `ImageRenderer` capture.

> **Front-end design quality bar:** thoughtful spacing and hierarchy, cohesive
> use of the panel's existing material/border language, subtle but present
> transitions (target switch, open), correct SF Mono metrics, and dense-but-
> legible log text. It should look hand-designed; reject the bland default.
>
> **Worker completion requirement:** complete **all** items above. Note any
> deferred item and why in your summary.

[Return to Top](#summary)

---

## Testing Milestone T3 — Screenshot review + hands-on browsing

**Recommended model:** Opus (nuanced UI-flow judgment + screenshot curation).
**Mode(s):** **screenshot review** (automated render via `ImageRenderer`) +
**hands-on** (live 29 GB workflow that fixtures can't show).

Screenshot review (worker-driven, no app launch required by the reviewer):

- [ ] Add a tiny `ImageRenderer`-based capture helper (or a `--dump-screenshots`
  debug path) that renders `AIStorageLogsSheet(model: fixture)` to PNG for each
  state below and writes them to `docs/screenshots/explore-logs-*.png`:
  - [ ] **empty** (a target with no files),
  - [ ] **populated** (file list with month sections + a selected `.log`),
  - [ ] **large-file tail banner** (the `showing last 256 KB of 10.5 MB` state),
  - [ ] **binary notice**,
  - [ ] **file-missing** state.
  - [ ] Capture each in **light and dark** appearance.
- [ ] Embed/link the PNGs in this doc (Progress Log) or the run summary so the
  user judges layout/spacing/hierarchy **inline**, without running the app.
- [ ] Record the user's visual sign-off (approve / requested changes) in the
  Progress Log.

Hands-on (behavioral — a rendered preview cannot show scroll/paging/timing).
Orchestrator walks the user through, then **pauses for sign-off**:

- [ ] Open the panel → **Explore logs…**, switch among the three targets.
- [ ] In `server-logs`, drill into a real month section, open a real **~10 MB**
  `YYYY-MM-DD.NN.log`; confirm tail-first render, auto-scroll to bottom,
  smooth scroll, and **Load full file** completing without a memory spike.
- [ ] Confirm **Reveal in Finder** selects the right file and the browser
  performed **no** deletion (directory contents unchanged).
- [ ] Filter `All / 30 days / 7 days` visibly narrows the list.

> Every state must be captured and every hands-on item walked. If the user
> requests visual changes, feed them back into M4 (or a gap-fill of M3).

[Return to Top](#summary)

---

## Milestone 4 — Polish, edge cases & accessibility

**Recommended model:** Opus (interaction/visual polish), Sonnet acceptable for
the pure-logic-only items below.

- [x] **Scroll-to-bottom correctness** on open and after *Load full file*
  (preserve position when loading more; jump to bottom on first open).
- [x] **Incremental paging** (optional but recommended for very large logs):
  page in older content on scroll-up rather than loading the whole file, to
  keep even a pathological multi-GB single file bounded.
- [x] **Cancellation:** cancel an in-flight `listFiles` when the sheet is
  dismissed or the target is switched mid-walk (no stale list applied).
- [x] **Deleted-file recovery:** re-list on demand from the file-missing state;
  re-list also when the target's dir changes on disk.
- [x] Confirm the 5-minute **scan cadence is untouched** — opening the browser
  does a fresh fast `listFiles` walk, it must not trigger a full
  `AIStorageModel.rescan()` or the 2s `MetricsManager` tick.
- [x] **Accessibility:** VoiceOver labels on file rows (name, size, date) and
  on the viewer; Dynamic Type on non-mono labels; the monospaced log body stays
  legible (a sensible floor) at larger sizes; focus/keyboard navigation
  (arrow keys move selection, Return opens).
- [x] **Dark/light** appearance pass on the whole sheet (materials, section
  header contrast, banner colors).

> **Worker completion requirement:** complete **all** items above (the
> "optional" paging item still gets attempted; defer only with a noted reason).

[Return to Top](#summary)

---

## Testing Milestone T4 — Regression & final sign-off

**Recommended model:** Sonnet (regression is mechanical) + Opus for the visual
sign-off of the final screenshots.
**Mode(s):** automated (SPM `XCTest` full run) + screenshot review (dark/light)
+ hands-on (end-to-end journey).

- [x] Run the **full** `swift test` suite; all green (no regressions to the
  pre-existing collector/filter tests or to the new T1/T2 cases).
- [x] Confirm the **existing** `AIStorageSearchSheet` and `AIStoragePurgeSheet`
  still build and are behaviorally unchanged (the new `isExplorable` field and
  injectable `root` must not alter scan/purge/search results).
- [ ] ~~Screenshot review~~ **(dropped — user does visual sign-off manually)**: final **light + dark** captures of the sheet in the
  populated and empty states, committed to `docs/screenshots/`, for the user's
  inline approval.
- [ ] ~~Hands-on **full journey**~~ **(dropped — user tests manually)** (orchestrator walks, then pauses for sign-off):
  panel → Explore logs… → pick target → drill month → open large log →
  Load full → Reveal in Finder → close → confirm nothing was deleted and the
  panel's *Search* / *Purge* still behave.
- [x] Update the **Milestone Progress Tracker** statuses/durations and the
  **Progress Log** with the final entry.

> All items must pass/be captured. This milestone gates the feature as done.

[Return to Top](#summary)

---

## Parallel Development Recommendations

The work is **largely sequential** because each layer depends on the previous
one, but there is one genuine parallel opportunity once M1 lands:

- **Sequential blocker:** **M1** must complete first — it defines
  `AIStorageFileEntry`, `isExplorable`, the pure helpers, and the preview
  fixture that *both* the collector tests (T1) and the UI (M3) depend on.
  Nothing else can start until M1 is merged.

- **Group A (can run in parallel after M1):**
  - **M2 + T2** (collector filesystem APIs + their integration tests) —
    depends only on M1's model + pure helpers.
  - **M3** (the UI sheet) — can be developed **in parallel with M2** against
    M1's **preview fixture** (`AIStorageSnapshot.preview` +
    `previewFileEntries`) and a stub of the M2 model wrappers. The UI does not
    need the *real* filesystem code to be laid out and designed; it swaps the
    stub for the real `listFiles`/`readTail`/`readFull` once M2 lands.
  - Assign Group A to two workers: Worker A owns
    `src/Services/AIStorageCollector.swift` (+ its tests), Worker B owns
    `src/Views/AIStorageLogsSheet.swift` + `AIStoragePanelView.swift`. No file
    overlap (Collector vs. Views), so no merge conflicts.

- **Sequential after Group A:**
  - **T3** requires M3's UI *and* M2's real APIs (to capture the large-file
    tail and run the live hands-on walk), so it starts after both.
  - **M4 → T4** run last, sequentially.

- **Orchestrator context management:** if dispatching the two Group A workers
  (plus any gap-fills) causes the orchestrator context to approach its limit,
  prompt the user to run **/compact** while the workers run. The orchestrator
  should monitor its own context usage and proactively suggest compacting near
  the limit; after compacting it resumes coordination by reading
  `.orchestrator/state.json`.

[Return to Top](#summary)

---

## Gap-Filling Prompt Requirements

When a milestone leaves items skipped or partially done, the orchestrator
generates a gap-fill prompt that:

- Follows the **same structure** as the original milestone prompt (header,
  mission statement, planning-doc reference to
  `local-llm-history-browser.md`, file list, completion instructions).
- States explicitly what was **already completed** in the original attempt and
  which specific checkboxes remain, so the worker does not redo finished work.
- References the original milestone's context and the files it already
  modified (`AIStorageCollector.swift`, `AIStorageLogsSheet.swift`,
  `SystemMetrics.swift`, the relevant test file).
- Lists **other active workers and their owned directories** (Collector vs.
  Views in Group A) to avoid conflicts.
- Is clearly labeled `Worker Context: [Milestone Name] - Gap Fill`.
- Carries the standard completion instructions:
  1. **Commit** code changes before writing the summary — and **do not mention
     claude or anthropic in the commit message** (repo convention). Also never
     commit `.claude/settings.local.json`.
  2. **Write the summary** to `.orchestrator/worker-summary-[milestone-slug]-gap.md`.
  3. **Prompt the user to close/clear the context** after completion.

[Return to Top](#summary)

---

## Progress Log / Notes

Reverse-chronological. Newest entries first. Format:
`**YYYY-MM-DD HH:MM** - [description]`.

- **2026-08-22 15:28** - **M4 complete** (commit `5ecc60c`, 16 min) — **including incremental
  paging, not deferred**. The viewer now holds byte *windows* (`LogChunk`) rather than one string:
  opening reads the 256 KB tail, scrolling to the top pages in the previous 256 KB via a sentinel
  row, and *Load full file* became the same call with `limit == windowStart`, so it **prepends and
  holds your reading position** instead of reloading. Scroll behaviour is now an explicit
  `ScrollIntent` (`.bottom` / `.keep(blockID:)`) applied once per revision. Listings run in a stored
  `listTask` cancelled on target switch and `.onDisappear`. A new `AIStorageDirectoryWatcher`
  (`O_EVTONLY` `DispatchSource`, coalesced at 1.2 s) re-lists on directory change, preserving the
  open file or falling through to the newest one on rotation. Full a11y pass (row labels with spoken
  dates, `.isHeader` sections, a distinct keyboard cursor with arrows/Return, `@ScaledMetric` on
  non-mono labels, mono body clamped to design+6). Dark-mode contrast fixes throughout.
  **API additions:** `sliceTail` gained `startOffset`; new `sliceWindow`, `readWindow`,
  `loadEarlier`; `AIStorageLogsSource.loadFull` replaced by `loadEarlier` (the collector's `readFull`
  is unchanged and still covered by T2). `swift test` **84/84**.
- **2026-08-22 15:32** - **T4 (automated scope) complete — feature done.** Verified in the main tree
  at `5ecc60c`: `swift build` clean, `swift test` **84/84, 0 failures**;
  `AIStorageSearchSheet.swift` and `AIStoragePurgeSheet.swift` **byte-identical** to their pre-feature
  state (`git diff a97c6a2..HEAD` empty), so search/purge behaviour is provably unchanged by the new
  `isExplorable` field and the injectable `root:`; no `removeItem`/`createFile`/`write`/`moveItem`
  call exists anywhere in the browser (the sole `.write` token is the directory watcher's *event
  mask*), and the sheet has no `rescan`/`scanIfStale` call site, so the 5-minute scan cadence and the
  2 s `MetricsManager` tick are untouched. The screenshot-review and hands-on items of T4 were
  **dropped per the user's directive** — they will do visual sign-off manually.
- **2026-08-22 15:02** - **T2 complete** (commit `7176679`, 12 min): 16 filesystem-integration cases
  over a fake `root:` — listing/ordering/`monthSection`/metadata, symlink-escape drop, cancellation
  (300 planted files so the per-256 stride check reliably fires), `readTail` small/truncated/denied/
  missing, `readFull`, and a byte-identical before/after tree snapshot proving the APIs never mutate.
  No M2 bug. **Test-infra gotcha worth remembering:** a fake root under `/tmp` or `/var/folders` sits
  behind macOS's `/tmp`→`/private/tmp` and `/var`→`/private/var` symlinks, which
  `URL.resolvingSymlinksInPath()` canonicalizes inconsistently with the enumerator's raw paths —
  spurious guard/`relativePath` failures unrelated to the collector. Fake roots are planted under the
  package's `.build/` instead.
- **2026-08-22 15:05** - **M3 merged and reconciled** (`cf7a08e` merge + `e534fc6` wiring). Orchestrator
  swapped `AIStorageLogsSource.live` to the real `AIStorageModel` wrappers, deleted M3's stand-in
  `AIStorageFileContent` in favour of M2's, and adapted the viewer from `state`/`.missing` to
  `access`/`.missingFile` (with `totalBytes` `UInt64` → `Int` at the format sites). Main tree:
  `swift build` clean, `swift test` **76/76 green**. Group A is fully landed; M4 dispatched.
- **2026-08-22 14:45** - **M3 built** (worker commit `aa72e14` on branch
  `worktree-agent-ab9f823a386b2b45b`; **merge to `main` deferred** until T2 finishes, to avoid two
  contexts building in the same `.build` dir). All 7 tasks done, nothing deferred: `AIStorageLogsSheet`
  (820 pt, 280 pt month-sectioned `LazyVStack` list with sticky headers + All/30/7 filter, SF Mono
  viewer with tail banner + Load full file, raw/pretty JSON toggle, Reveal in Finder, and designed
  binary / missing / denied placeholders), plus the `Explore logs…` panel button gated on
  `containsExplorable`. Two notable engineering calls: log text renders in **400-line blocks** inside
  a `LazyVStack` (a single `Text` over a 10 MB file would hang TextKit; selection doesn't span
  blocks), and the split text is cached in `@State` rather than recomputed in `body`. Worktree again
  started stale at `4d270b9` and was reset to `a97c6a2`. **Reconciliation owed at merge:** M3's stub
  `AIStorageFileContent` must be deleted in favour of M2's, three `AIStorageLogsSource.live(model:)`
  closures swapped to the real calls, and the viewer's `state`/`.missing` switch adapted to M2's
  `access`/`.missingFile` (plus `totalBytes` `UInt64` → `Int`).
- **2026-08-22 14:34** - **M2 complete** (worker commit `229b07f`, merged to `main` as `e996654`,
  9 min). Injectable `root:` on the collector, `listFiles` (recursive, hidden files, symlink-resolved
  root-guard with drop-not-throw, `newestFirst` sort, `Task.checkCancellation()` every 256 files),
  `readTail`/`readFull`, and the `AIStorageModel` wrappers + `AIStorageFileContent`.
  **Deviation (accepted):** rather than overloading `("", 0, false)` to mean both "denied" and
  "vanished", the reads return a `ReadStatus` / `AIStorageFileAccess` enum (`.ok / .denied /
  .missingFile`) — the prompt invited deciding the representation, and this one is `Equatable` and
  testable. Known limitation for M3: `AIStorageModel.listFiles` collapses errors *and*
  `CancellationError` into `[]` via `try?`, so the UI cannot distinguish cancelled from empty.
  Main tree after merge: `swift build` clean, `swift test` **60/60**. The worktree started stale at
  `4d270b9` and the worker correctly `reset --hard`ed to `a97c6a2`. T2 dispatched.
- **2026-08-22 14:20** - **T1 complete** (commit `831bd57` on `main`). Full pure-helper matrix:
  `AIStorageLogLayoutTests` expanded (month-section incl. year boundaries + locale independence,
  `newestFirst` ordering/tiebreak), new `AIStoragePathGuardTests` (accept/deny matrix including a
  `.lmstudio-evil/` prefix-trap that confirms segment-wise matching, all four never-touch paths
  directly and nested, bare root dirs denied), new `AIStorageTailReaderTests` (empty, small,
  truncated, non-torn first line, no-newline fallback, lossy non-UTF8 decode).
  `swift test` **60/60 green**. No helper bugs found; the collector was left untouched.
- **2026-08-22 14:12** - **M1 complete** (commit `a97c6a2`, 7 min). `AIStorageFileEntry`,
  `isExplorable` on target/spec/snapshot, the three pure helper enums
  (`AIStorageLogLayout` / `AIStoragePathGuard` / `AIStorageTailReader`) and the extended
  `#if DEBUG` preview fixture all landed. `swift test` 40/40 green (35 pre-existing + 5 new
  scaffold cases). One flagged judgment call: the doc's `looksBinary` "oMLX cache/vision
  extensions" are named nowhere in the codebase, so a placeholder binary set
  (safetensors/npy/npz/bin/pt/gguf) was used — largely moot since those targets are
  `isExplorable: false`. Group A dispatched in parallel: **M2** (Sonnet, worktree, collector
  FS APIs), **M3** (Opus, worktree, UI sheet), **T1** (Sonnet, main tree, pure-helper tests).
- **2026-08-22 14:05** - Orchestrator session started (slug `local-llm-history-browser`).
  Removed a stale `active-sessions.json` entry (`local-llm-history-browser-local`, planning doc
  and session folder both gone). **User directive: skip testing phases, unit tests are okay** —
  T3 (screenshot review + hands-on) is **skipped entirely**, T4 is reduced to an automated
  `swift test` regression run, and M4's screenshot/dark-light capture items are dropped. T1 and
  T2 (XCTest unit + filesystem integration) remain in scope. User handles visual/manual sign-off.
  M1 dispatched to a Sonnet worker.
- **2026-08-22 13:08** - Plan created for the read-only *Explore Logs* browser
  on the Local AI Storage panel. Defaults baked in: incremental testing
  (T1–T4 after each worker milestone); automated-first via SPM `XCTest`
  (the suite already exists — 9 files, CLAUDE.md's "no test suite yet" is
  stale), `ImageRenderer` screenshot review for UI sign-off, hands-on only for
  the live ~29 GB `server-logs` workflow; scope limited to the three log
  targets (`server-logs`, `conversations`, `omlx.logs`); ~820 pt two-column
  sheet; tail-first large-file rendering; injectable collector root for
  testability. No DB, so no Schema Review Milestone. Group A (M2+T2 ∥ M3) can
  run in parallel after M1. Awaiting user approval to begin M1.

[Return to Top](#summary)

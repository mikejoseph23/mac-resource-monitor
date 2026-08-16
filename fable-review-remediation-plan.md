# Mac Resource Monitor — Review Remediation Plan

> Structured execution plan derived from `fable-review-july-17.md` (QA & Design Review, July 17, 2026). Each finding is mapped to a milestone with actionable, checkbox-tracked items, a recommended model, and incremental testing gates.

## Summary

**Goal:** Ship the fixes surfaced by the July 17 review — two crash-class bugs, a set of leaks/correctness guards, four visible-today UI bugs, a main-thread-collection refactor, and a round of design polish — without regressing the app's already-strong light/dark handling and dashboard layout.

**Key objectives:**

- Eliminate the two crash-class defects (signed CPU-tick cast; escaped/unaligned NetworkCollector pointer) that will bite an always-on Mac Studio.
- Fix the four user-visible bugs (blank menu-bar GPU icon, hardcoded LM Studio status, mis-plotted Thermal/Frequency sparklines, stale v0.1.0 About panel).
- Move metric collection off the main actor so the UI stops stuttering every 2s tick.
- Close the leaks and add the cheap under/overflow guards.
- Unify severity colors/thresholds and land the quick design wins.
- Optionally tackle the bigger features (process kill, search, live menu-bar icon).

**Critical success factors:**

- No new crashes; collectors stay numerically correct across counter wrap, sleep/wake, and PID reuse.
- UI remains smooth (no main-thread blocking) and visually consistent (one `MetricSeverity` source of truth).
- Each code milestone is verified before the next dependent one starts (incremental testing).

**Defaults applied** (override any you disagree with):

- **Testing strategy:** incremental — a testing milestone follows each logical group of code milestones.
- **Testing modes:** XCTest unit tests for collector logic (crash guards, underflow, wrap); screenshot review for the UI-facing fixes (worker builds/runs the app, captures the relevant cards/menu-bar/About states in light **and** dark, and drops the images inline for sign-off — you don't launch the app); hands-on only for the interactive new features (kill action, search).
- **No Schema Review milestone:** this is a native SwiftUI app with no database.
- **No Playwright:** not a web app — screenshot review uses the app's own rendered windows.
- **Models:** systems/concurrency and all UI-design milestones → Opus; mechanical fixes and test-writing → Sonnet.

### Milestone Progress Tracker

| Milestone | Model | Status | Duration (min) | Notes |
|-----------|-------|--------|----------------|-------|
| M1 — Visible UI bugs (design 1–4) | Sonnet | ✅ Done | 3 | Commit c9b7314 · verified in source |
| M2 — Crash-class + leaks (QA 2,3,4,5) | Opus | ✅ Done | 2 | Commit 9478f93 · verified in source |
| T1 — Test: collectors + UI-bug screenshots | Sonnet | ✅ Done | 36 | Commit 0284c98 · 8 tests green · light screenshots signed off (dark skipped, T3 covers) |
| M3 — Off-main collection refactor (QA 1) | Opus | ✅ Done | 3 | Commit 83eaf45 · new CollectionEngine actor · TSan-clean · smoothness → T2 |
| M4 — Remaining QA (6,7,8,9,10) | Sonnet | ✅ Done | 3 | Commit 37162d9 · LMStudio→actor (see M3) |
| T2 — Test: refactor + M4 regression | Sonnet | ✅ Done | 8 | Commit 564ed08 · 16 tests green · smoothness signed off by user |
| M5 — Design quick wins (design 5–9) | Opus | ✅ Done | 9 | Commit e55a194 · verified in source |
| T3 — Test: design screenshot review | Opus | ✅ Done | 15 | 18 shots (light+dark) · M5 approved · flags process-row 70/90 as too insensitive |
| M6 — Bigger features (design 10–15) | Opus | ✅ Done (subset) | 8 | #10,#11 (`d8d3e3a`) + #12,#13 (`fcd2a63`) shipped. #14,#15 deliberately skipped. → T4 hands-on |
| T4 — Test: feature workflows (hands-on) | Sonnet | ✅ Done | 68 | #10,#11,#13 PASS · #12 bug fixed & re-verified (`38eee02`) · 35 tests green |

---

## Table of Contents

- [Summary](#summary)
- [M1 — Visible UI Bugs](#m1--visible-ui-bugs)
- [M2 — Crash-Class Fixes & Leaks](#m2--crash-class-fixes--leaks)
- [T1 — Testing: Collectors & UI-Bug Screenshots](#t1--testing-collectors--ui-bug-screenshots)
- [M3 — Off-Main Collection Refactor](#m3--off-main-collection-refactor)
- [M4 — Remaining QA Findings](#m4--remaining-qa-findings)
- [T2 — Testing: Refactor & M4 Regression](#t2--testing-refactor--m4-regression)
- [M5 — Design Quick Wins](#m5--design-quick-wins)
- [T3 — Testing: Design Screenshot Review](#t3--testing-design-screenshot-review)
- [M6 — Bigger Features](#m6--bigger-features)
- [T4 — Testing: Feature Workflows](#t4--testing-feature-workflows)
- [Parallel Development Recommendations](#parallel-development-recommendations)
- [Gap-Filling Prompt Requirements](#gap-filling-prompt-requirements)
- [Progress Log / Notes](#progress-log--notes)

> Every milestone requires the worker to complete **all** listed items. Do not skip an item because it looks low-priority or slightly out of scope. If you believe an item should be deferred or removed, still attempt it unless truly blocked, and flag it in your summary for the orchestrator to decide.

---

## M1 — Visible UI Bugs

**Model:** Sonnet · **Depends on:** none · **Design findings 1–4**

Pure bug fixes to user-visible surfaces — no design judgment required, so Sonnet is fine.

- [x] Fix blank menu-bar GPU icon: `MenuBarView.swift:46` uses `"gpu"` (not an SF Symbol). Change to `"rectangle.3.group"` to match `DashboardView.swift:419`.
- [x] Fix hardcoded LM Studio status: `MenuBarView.swift:73` hardcodes `"Not Connected"`. Read real state from `snapshot.lmStudio` the way the dashboard does; render actual connected/disconnected label and color.
- [x] Fix Thermal card sparkline: `DashboardView.swift:588` plots GPU utilization on the Thermal card. Plot the card's own thermal metric, or drop the sparkline if no suitable series exists. *(Dropped — `ThermalMetrics` has no numeric series; passed `[]`.)*
- [x] Fix Frequency card sparkline: `DashboardView.swift:561-564` plots watts with a `"%.2f W"` formatter on a GHz card (hovering "1.46 GHz" shows "0.20 W"). Plot the frequency series with a GHz formatter, or drop the sparkline. *(Added `pcpuFrequencyHistory` helper + `%.2f GHz` formatter.)*
- [x] Fix About panel version: `MacResourceMonitorApp.swift:21` says `"0.1.0"`. Update to the shipped release (`1.1.0`); consider sourcing from the bundle's `CFBundleShortVersionString` so it can't drift again. *(Now reads `CFBundleShortVersionString`, falls back to `1.1.0`.)*
- [x] Build clean (`swift build`) and confirm no new warnings introduced by these edits.
- [x] Commit changes before writing the worker summary.

[Return to Top](#table-of-contents)

---

## M2 — Crash-Class Fixes & Leaks

**Model:** Opus · **Depends on:** none (independent of M1) · **QA findings 2, 3, 4, 5**

Systems-level correctness: signed/unsigned tick math, pointer aliasing/alignment, and Mach port lifetime. Nuanced enough to warrant Opus.

- [x] **QA #2 — signed CPU-tick cast (crash-class).** `CPUCollector.swift:39-42` does `UInt64(info[...])` on `Int32` ticks that are really unsigned; once a per-core counter passes 2³¹ it reads negative and traps (~248 days of core uptime). Change to `UInt64(UInt32(bitPattern: info[...]))` for all four state reads (user/system/idle/nice).
- [x] **QA #5 — CPU delta underflow on wrap.** `CPUCollector.swift:58-61` computes `currentTicks - prev` as unguarded `UInt64` subtraction; a 32-bit wrap yields one garbage spike. Guard with a `>=` check (mirror the pattern DiskCollector/NetworkCollector already use) and drop/zero the sample on wrap.
- [x] **QA #4 — NetworkCollector escaped/unaligned pointer (crash-class).** `NetworkCollector.swift:94-105` returns a raw pointer out of `withUnsafeBufferPointer` (UB after the closure ends) and does typed `load(as: if_msghdr2.self)` with no 8-byte alignment guarantee. Refactor to do all struct reads **inside** the closure and use `loadUnaligned(fromByteOffset:as:)`. *(Now inside `withUnsafeBytes` + `loadUnaligned` + bounds checks.)*
- [x] **QA #3 — leaked host port.** `CPUCollector.swift:14` and `MemoryCollector.swift:24` call `mach_host_self()` every 2s without `mach_port_deallocate`, growing the port ref count unbounded. Cache the host port once (e.g. a stored `let` / lazy static) and reuse it; add deallocation only if a fresh port is genuinely acquired per call. *(Cached as `private let hostPort` in both collectors.)*
- [x] Re-read the review's "Verified clean" note — do **not** touch sleep/wake rate handling, backward-clock guards, or IOReportBridge CF refcount balance; they're already sound.
- [x] Build clean (`swift build`) and run the app briefly to confirm CPU/Network/Memory cards still populate with sane values. *(Build clean; ~8s run, no trap. Full visual card sign-off deferred to T1.)*
- [x] Commit changes before writing the worker summary.

[Return to Top](#table-of-contents)

---

## T1 — Testing: Collectors & UI-Bug Screenshots

**Model:** Sonnet · **Depends on:** M1, M2 · **Modes:** XCTest unit tests + screenshot review

This is the first place a test target is introduced — set up `Tests/` in `Package.swift` if not present.

**Unit / integration (automated):**

- [x] Add an XCTest target to `Package.swift` if none exists; get `swift test` running green with one trivial test first. *(`MacResourceMonitorTests` target added.)*
- [x] Write a test proving `UInt64(UInt32(bitPattern:))` yields the correct unsigned value for a tick sample near/over 2³¹ (the QA #2 fix). *(Via extracted `CPUCollector.unsignedTicks(from:)` seam.)*
- [x] Write a test for the CPU delta wrap guard (QA #5): a current-below-previous pair must not produce a huge spike (expect zeroed/skipped delta). *(Via `CPUCollector.tickDelta(current:previous:)` seam.)*
- [x] If NetworkCollector parsing can be exercised with a synthetic `if_msghdr2` buffer, add a test that the unaligned read returns expected counters; otherwise document why it's build/run-verified only. *(Synthetic buffer forces non-8-byte offset; `parseIFList2Buffer` seam asserts 64-bit counters via `loadUnaligned`.)*
- [x] Run the full suite green (`swift test`) and paste the summary line into the worker summary. *(8 tests, 0 failures — orchestrator re-ran and confirmed green.)*

**Screenshot review (human visual sign-off — inline, no app launch by user):**

- [x] Worker builds and runs the app, then captures and saves images of: the **menu-bar popover** (GPU icon now visible; LM Studio row showing real status in both connected and disconnected states if reproducible), the **Thermal card** and **Frequency card** (hover/sparkline showing correct metric+unit), and the **About panel** (correct version). *(4 light-mode screenshots in `.orchestrator/screenshots/t1/`. LM Studio only reproducible as Connected — real instance running; disconnected state not forced.)*
- [~] Capture each in **light and dark** appearance. *(Light only — dark skipped per user direction mid-task; user accepted, T3 provides the full dark-mode design pass.)*
- [x] Embed/link the saved images in this doc (or the worker summary) for inline sign-off; the user reviews without launching the app. *(Orchestrator reviewed all 4; user signed off light-mode.)*

- [x] Commit tests before writing the worker summary. *(Commit `0284c98`.)*

[Return to Top](#table-of-contents)

---

## M3 — Off-Main Collection Refactor

**Model:** Opus · **Depends on:** M2, T1 (build on verified-correct collectors) · **QA finding 1**

The one users feel constantly. `MetricsManager` is `@MainActor` and calls every collector synchronously (`MetricsManager.swift:86-94`); `IOReportBridge.sampleDelta` does `Thread.sleep` for 100ms (`IOReportBridge.swift:161`) on the UI thread every tick, and `ProcessCollector` enumerates every PID with multiple syscalls each — all on main. Result: recurring scroll/animation stutter.

- [x] Move the per-tick collection work off the main actor (e.g. run collectors in a detached/background task or a dedicated actor), hopping back to the main actor only for the final `@Published` `SystemSnapshot` assignment. *(New `CollectionEngine` actor runs `collect()` off-main; `MetricsManager` only `await`s the snapshot + does `@Published`/`history.append` on main.)*
- [x] Ensure collectors that hold cross-sample delta state remain correct when driven from a non-main context (no data races on their `previous*` fields). *(All 9 sync collectors confined as `private let` on the engine actor → `previous*` state only ever touched on its serial executor.)*
- [x] Verify the 2s cadence is preserved and snapshots don't overlap/reenter if a collection pass runs long. *(MainActor-isolated `isCollecting` guard drops overlapping ticks; 2s Timer unchanged.)*
- [x] Confirm `IOReportBridge`'s 100ms sleep no longer occurs on the main thread. *(Now runs on the engine executor via GPU/Power collectors; no `IOReportBridge` source change needed.)*
- [x] Sanity-check with the Thread Sanitizer / a brief run that no main-thread hangs are reported during collection. *(`swift build --sanitize=thread`, ~12s run → 0 TSan reports, no main-thread hang.)*
- [x] Build clean and commit before writing the worker summary. *(Clean build; `swift test` 8/0 still green — orchestrator re-verified.)*

[Return to Top](#table-of-contents)

---

## M4 — Remaining QA Findings

**Model:** Sonnet · **Depends on:** M2 (shares collector files) · **QA findings 6, 7, 8, 9, 10**

Medium/low correctness cleanups.

- [x] **QA #6 — GPU multi-accelerator + bridging.** In `GPUCollector.swift:20-51` the IOAccelerator loop lets the last-enumerated node win; pick the correct/primary accelerator deliberately. Fix the core-count read: it uses `as? Int` while utilization correctly uses `as? NSNumber` — IORegistry ints bridge as `NSNumber`, so `as? Int` silently fails into the hardcoded default. Use `as? NSNumber` consistently. *(Loop now locks to first accelerator reporting PerformanceStatistics; all reads via `as? NSNumber`.)*
- [x] **QA #7 — core-count fallbacks.** `GPUCollector.swift:83-101` returns GPU core count 0 for unlisted chips and hardcodes M3 Ultra 80 / Ultra ANE 32, so gauges read 0 or wrong on M4/M5. Provide a sensible non-zero fallback and/or derive core count where the API allows; note the hardcoded default in a comment. *(Per-chip table M1–M4 + tier fallback Ultra/Max/Pro/base; commented as manually maintained.)*
- [x] **QA #8 — memory `freeBytes` underflow.** `MemoryCollector.swift:48` computes `totalBytes - usedBytes` with no clamp; a transient over-sum shows multi-exabyte "free". Clamp to `0` with a subtraction guard. *(Now `totalBytes > usedBytes ? … : 0`.)*
- [x] **QA #9 — LMStudioCollector off-thread write.** `LMStudioCollector.swift:9,23` writes `latest` off-thread with no synchronization. Harmless today (only the return value is used) but add synchronization (or document the invariant) to prevent a future-reader race — coordinate with M3's threading model. *(Converted to `actor` — compiler-enforced isolation; already called with `await`, M3-compatible. **M3 must account for this.**)*
- [x] **QA #10 — process CPU% glitch on PID reuse.** `ProcessCollector.swift:39-42` keys `previousCPUTimes` by PID; a recycled PID diffs a new process against the dead one for one sample. Include a start-time (or equivalent) in the key so reused PIDs don't cross-contaminate. *(New `ProcessIdentity` = pid + start-time key via `proc_pidinfo`/`pbi_start_tvsec`.)*
- [x] Build clean and commit before writing the worker summary.

[Return to Top](#table-of-contents)

---

## T2 — Testing: Refactor & M4 Regression

**Model:** Sonnet · **Depends on:** M3, M4 · **Modes:** XCTest + hands-on smoothness check + screenshot review

**Unit / integration (automated):**

- [x] Add a test for the memory `freeBytes` clamp (QA #8): an over-sum input must yield `freeBytes == 0`, never a huge value. *(Via `clampedFreeBytes` seam; 3 tests.)*
- [x] Add a test for the PID-reuse key (QA #10): same PID with a different start-time must not reuse the prior CPU-time baseline. *(`ProcessIdentity` → internal; 2 tests, distinct-identity + equal-identity.)*
- [x] If GPU parsing is unit-testable via injected registry values, assert `as? NSNumber` path returns the real core count instead of the default; otherwise verify by run. *(Extracted `parseAcceleratorStats(perfStats:topLevelDict:)`; 3 tests — NSNumber path, top-level fallback, missing→default.)*
- [x] Run `swift test` green and record the summary. *(16 tests, 0 failures — orchestrator re-ran and confirmed.)*

**Hands-on (interactive — smoothness is behavioral, a screenshot can't show it):**

- [x] Run the app for a few minutes; scroll the process list and switch tabs while collection ticks. Confirm the M3 refactor removed the periodic stutter (no visible hitch every ~2s). *(Worker CPU-sampling proxy — flat 2.6–3.0%, no tick-correlated spikes; screen contention with T3 blocked the literal scroll test.)*
- [x] Orchestrator pauses for user sign-off on smoothness. *(**User confirmed smooth 2026-07-17 — M3 stutter-removal signed off.**)*

**Screenshot review:**

- [x] Capture the GPU card showing a correct non-zero core count and utilization (light + dark); embed inline for sign-off. *(`screenshots/t2/gpu-card-{light,dark}.png` — 80 cores, M3 Ultra, 32-core ANE, non-zero util. Confirms QA #6/#7 end-to-end.)*

- [x] Commit tests before writing the worker summary. *(Commit `564ed08`.)*

[Return to Top](#table-of-contents)

---

## M5 — Design Quick Wins

**Model:** Opus (UI design work) · **Depends on:** M1 (visible bugs cleared first) · **Design findings 5–9**

Front-end design craft required — centralized severity system and card-level visual decisions. Apply genuine design taste: consistent thresholds, colorblind-safe cues, clear hierarchy, subtle transitions. Reference the polish level of Apple's own menu-bar utilities and iStat/Stats rather than bland defaults.

- [x] **#5 — unify severity.** Today menu bar uses green/yellow/red at 50/80, cards green/orange/red at 70/90, process rows 40/80, disk 80/95. Introduce one `MetricSeverity` (thresholds + colors) and route all four surfaces through it so the same "warning" state looks the same everywhere. *(New `src/Models/MetricSeverity.swift`; `.utilization` 70/90 for menu bar/cards/process rows, `.capacity` 80/95 preset for disk. **Process rows moved 40/80→70/90 — flag for T3.**)*
- [x] **#6 — severity not color-only.** On Network/Thermal/Power cards the sole cue is a 6px dot (`MetricCardView.swift:47`) — not colorblind-safe. Pair color with a shape or SF Symbol (e.g. distinct glyphs per severity). *(Glyphs: `circle.fill`/`exclamationmark.triangle.fill`/`exclamationmark.octagon.fill` + accessibility labels.)*
- [x] **#7 — headline number.** In %-mode, memory shows "19%" large and "96.6 / 512 GB" in 10pt tertiary (`MetricCardView.swift:71-74`). For the inference use case the GB figure is what matters — bump its contrast/size, or default the Local Inference profile to Actual (GB) mode. *(Subtitle 10pt tertiary → 11pt medium secondary, global; DisplayMode toggle left user-controlled.)*
- [x] **#8 — sparkline scale.** Auto-ranged sparklines (`SparklineView.swift:42-44`) make flat-low and flat-high look identical. Add a small max/current label (or a faint baseline) so the scale is legible. *(Faint min/max corner labels, `showScaleLabels` default on, hidden while hovering.)*
- [x] **#9 — Disk card split.** The Disk card mixes capacity % (gauge) with I/O MB/s (sparkline/value) (`DashboardView.swift:445-483`) — two unrelated metrics. Split into two cards, or pick the primary metric for the card and demote the other. *(Split into Disk (capacity) + new `.diskIO` widget (throughput); added to both profiles' grid order.)*
- [x] Preserve the already-strong light/dark handling (semantic colors + materials) — verify nothing regresses in either appearance. *(All new colors system-semantic; no appearance hardcoded.)*
- [x] Build clean and commit before writing the worker summary.

[Return to Top](#table-of-contents)

---

## T3 — Testing: Design Screenshot Review

**Model:** Opus (nuanced visual assertions) · **Depends on:** M5 · **Mode:** screenshot review (primary)

Moderate-to-advanced UI surface → human visual sign-off, defaulting to inline screenshots.

- [x] Worker builds/runs the app and captures each card type at each severity state (normal / warning / critical) showing the unified colors **and** the new shape/symbol cue. *(Forced via uncommitted scratch injector, reverted after; dot/triangle/octagon glyphs confirmed.)*
- [x] Capture the memory card in both %-mode and Actual (GB) mode showing the improved headline hierarchy. *(See minor note: GB hero string truncates in span-1 grid cards — M6 backlog candidate, pre-existing to the ring gauge.)*
- [x] Capture a sparkline in flat-low vs flat-high states demonstrating the new scale label disambiguates them. *(Line identical; min/max labels (KB/s vs MB/s) disambiguate — feature working.)*
- [x] Capture the split Disk card(s). *(Disk capacity + Disk I/O confirmed separate.)*
- [x] All of the above in **light and dark**. *(18 shots; closes the deferred T1 dark-mode pass — menu bar, Thermal/Frequency, About all captured in dark.)*
- [x] Embed/link the saved images inline for the user to judge layout, hierarchy, and colorblind-safety without launching the app; orchestrator pauses for sign-off. *(In `screenshots/t3/`; orchestrator reviewed critical-dark + processes-light.)*
- [x] Optional: add a lightweight snapshot test if the project adopts one; otherwise screenshot review is the gate. *(None added — screenshot review is the gate, as allowed.)*

[Return to Top](#table-of-contents)

---

## M6 — Bigger Features

**Model:** Opus · **Depends on:** M3 (stable threading), M5 (unified UI) · **Design findings 10–15** · **Stretch/optional**

Larger scope — treat as an à-la-carte backlog; the orchestrator can pursue a subset. Each is independently shippable.

- [x] **#10 — Process kill/quit action.** Most-expected missing feature vs Activity Monitor/iStat/Stats. Add a context menu on process rows (SIGTERM "Quit", SIGKILL "Force Quit") with a confirmation for force-kill. *(M6-A `d8d3e3a`: context menu on leaf + group rows; Force Quit confirms; `kill()` errors (EPERM/ESRCH) surfaced via alert; grouped rows signal all child PIDs with count in the label; rows self-remove next tick. **T4 hands-on.**)*
- [x] **#11 — Live process search field.** Filtering today is profile-driven substring only (`DashboardLayout.swift:61`). Add a live search field that filters the process list by name/PID. *(M6-A `d8d3e3a`: search field in ProcessListView's own header; live name (case-insensitive) + PID match via pure `ProcessSearchFilter.apply`; composes with profile filter + grouping; 7 unit tests. **T4 hands-on.**)*
- [x] **#12 — Live menu-bar icon.** The static gauge (`MacResourceMonitorApp.swift:27`) wastes the main reason people run a bar monitor. Render live CPU/GPU/mem text or a mini-graph in the menu bar. *(M6-B `fcd2a63`: `MenuBarLabel` live CPU%/GPU% on the 2s tick. **Fixed `38eee02`** — T4 found the GPU segment clipped by `MenuBarExtra`'s fixed status-item width; rewritten as a single concatenated `Text` ("CPU 12% GPU 20%"), verified on-screen light+dark, low+high load. **Known platform limitation (backlog):** macOS renders the label as a monochrome template, so severity color doesn't paint — needs a custom `NSStatusItem` to change.)*
- [x] **#13 — Standard Settings scene (⌘,).** Replace the slider-icon popover (`DashboardView.swift:175`) with a real Settings scene for widget visibility, launch-at-login, and a GPU-core-count override (ties into QA #7). *(M6-B `fcd2a63`: `Settings` scene + new `SettingsView` (General/Widgets tabs); launch-at-login via `SMAppService`; GPU override resolved via `GPUCollector.resolveCoreCount` reading `UserDefaults` inside the engine-actor's `collect()`; old popover removed cleanly. 4 override tests → 20/20 green.)*
- [ ] **#14 — Native `Table` for the process list.** `ProcessListView.swift:559` is hand-built HStacks; migrate to SwiftUI `Table` — worth it when adding selection/kill (#10). *(**Deliberately skipped** — user deselected this session; #10 was built on the existing HStack rows. Backlog.)*
- [ ] **#15 — Compact / float-on-top mode.** Min size is 860×660 (`DashboardView.swift:120`); add a compact corner-widget / always-on-top mode. *(**Deliberately skipped** — user deselected this session. Backlog.)*
- [x] Build clean and commit each feature before writing the worker summary. *(M6-B `fcd2a63`, M6-A `d8d3e3a`; suite 27/27 green.)*

[Return to Top](#table-of-contents)

---

## T4 — Testing: Feature Workflows

**Model:** Sonnet · **Depends on:** M6 (only if pursued) · **Modes:** hands-on + screenshot review

Interactive/behavioral features — hands-on where a screenshot can't convey the workflow.

- [x] **Kill action (hands-on):** launch a throwaway process, quit it from the context menu (SIGTERM), confirm it disappears; verify force-quit path and its confirmation dialog. User sign-off. *(PASS: SIGTERM on `sleep`, SIGKILL + confirmation, permission alert on root `notifyd` no-crash, grouped "Xcode (23 processes)" label verified.)*
- [x] **Search (hands-on):** type a query, confirm live filtering by name and PID, confirm clearing restores the full list. *(PASS: live name + PID narrowing, group-collapse, composes within profile filter, clear restores.)*
- [x] **Live menu-bar icon (screenshot + brief run):** capture the bar rendering under low and high load; confirm it updates on the tick cadence. *(Live update confirmed 7→8→10→19%; GPU-segment clip bug found → fixed `38eee02`, re-verified both segments render light+dark.)*
- [x] **Settings scene (hands-on):** toggle widget visibility and launch-at-login, set a GPU-core override, confirm each persists and takes effect. *(All PASS on a real `.app` bundle: grid reflow, GPU 40↔auto-80, `SMAppService` register/unregister, persistence across relaunch.)*
- [x] Add unit tests for any non-trivial logic introduced (filter predicate, core-count override plumbing) and run `swift test` green. *(Search predicate 7 + GPU override 4 pre-covered; added ProcessKillTarget ×5 + MetricSeverity ×3 → 35/35 green.)*
- [x] Commit before writing the worker summary. *(T4 tests `15a4906`; menu-bar fix `38eee02`.)*

[Return to Top](#table-of-contents)

---

## Parallel Development Recommendations

**Sequential blockers:**

- **T1** gates M3 (refactor should build on verified-correct collectors).
- **M3** should land before M6's threading-sensitive features (#12 live bar) and before M4's #9 synchronization is finalized.

**Parallel Group A (can start immediately, no cross-dependencies):**

- **M1** (Views: `MenuBarView`, `DashboardView`, `MacResourceMonitorApp`)
- **M2** (Services: `CPUCollector`, `MemoryCollector`, `NetworkCollector`)

  These touch disjoint files — safe to run concurrently by two workers.

**Parallel Group B (after M2 lands; M4 and M5 touch different layers):**

- **M4** (Services: `GPUCollector`, `MemoryCollector`, `LMStudioCollector`, `ProcessCollector`)
- **M5** (Views + a new `MetricSeverity`)

  Minor overlap risk: M4 and M2 both touch `MemoryCollector` — sequence M4 after M2, not alongside it. M5 vs M1 both touch `MenuBarView`/`DashboardView` — sequence M5 after M1.

**Within M6:** #10, #11, #12, #13, #15 are largely independent; #14 (`Table` migration) should precede or merge with #10 (kill/selection) since they touch the same list. Assign one worker per feature with `isolation: worktree` if run in parallel to avoid file conflicts.

**Orchestrator context management:** If dispatching multiple worker prompts fills the orchestrator context, run `/compact` while workers run. Monitor context usage and compact proactively near the limit; after compacting, resume by reading `.orchestrator/state.json`.

[Return to Top](#table-of-contents)

---

## Gap-Filling Prompt Requirements

If a milestone finishes with items skipped or partial, generate a follow-up ("gap-fill") prompt that:

- Follows the same structure as the original milestone prompt (header, mission statement, planning-doc reference).
- Is labeled **"Worker Context: [Milestone Name] — Gap Fill"**.
- States what was already completed in the original attempt and which files were modified.
- Lists other active workers and their directories to avoid conflicts.
- Ends with the standard completion steps:
  1. **Commit code changes** before writing the summary.
  2. **Write summary** to `.orchestrator/worker-summary-[milestone-slug]-gap.md`.
  3. **Prompt the user to close/clear the context** after completion.

[Return to Top](#table-of-contents)

---

## Progress Log / Notes

**2026-07-17 21:22** — **#12 menu-bar GPU-clip bug FIXED** (Worker, Opus, 11 min, commit `38eee02`). Root cause confirmed: `MenuBarExtra(.window)` sizes its `NSStatusItem` from the first render and never grows it, so the two-segment `HStack` had its GPU half clipped (item pinned ~61pt). Rewrote `MenuBarLabel` as a single concatenated `Text` ("CPU 12%   GPU 20%", `--%` placeholders pre-snapshot) → item grows to ~148pt, both segments render. Verified on a real `.app` bundle via screenshots: light `CPU 11% GPU 18%`, dark `CPU 8% GPU 18%`, dark high-load `CPU 100% GPU 16%`. Live update + monospaced digits preserved; only `MacResourceMonitorApp.swift` touched; 35/35 tests still green. **T4 now fully signed off.** *(New backlog item: severity color doesn't paint in the menu bar — macOS renders the label as a monochrome template; SF Symbols also don't paint inside a menu-bar `Text`, hence CPU/GPU word labels. Both would need a custom `NSStatusItem` — larger task, deferred.)*

**2026-07-17 (plan complete)** — **All milestones closed.** Core plan M1–M5 + test gates T1–T4 done; M6 subset (#10 kill, #11 search, #12 live menu-bar, #13 Settings) shipped; M5 process-row severity gap-fill landed; the one T4-found bug (#12 GPU clip) fixed and re-verified. Final commit `38eee02`. Test suite: **35 tests, 0 failures.** All work committed locally on `main` (not pushed — awaiting user). **Backlog (documented, not lost):** #14 native `Table`, #15 compact/float-on-top mode, Actual-GB ring-gauge hero truncation in span-1 cards, menu-bar severity coloring (custom `NSStatusItem`).

**2026-07-17 21:06** — **T4 (Feature Workflows, hands-on) — PARTIAL** (Worker, Sonnet, ~68 min, commit `15a4906`). Built a real ad-hoc-signed `.app` bundle to exercise launch-at-login for real. **#10 kill PASS** (SIGTERM on throwaway `sleep`, SIGKILL + confirmation dialog, permission-denied alert on root-owned `notifyd` with no crash, grouped "Xcode (23 processes)" label verified by read-only dismiss). **#11 search PASS** (live name + PID narrowing, group-collapse, composes within Local Inference profile filter, clear restores). **#13 Settings PASS** (⌘, opens; widget toggles reflow grid live; GPU override 40↔auto-80 flows to card; launch-at-login registered via `SMAppService` in the bundle then unregistered; all settings persist across relaunch). Added 8 tests (`ProcessKillTargetTests` ×5, `MetricSeverityTests` ×3 — the severity enum had zero prior coverage) → **35/35 green**. **⚠️ #12 menu-bar icon FAIL — real bug:** `MenuBarLabel` composes CPU+GPU segments but only CPU renders; GPU segment (`rectangle.3.group` + GPU%) is clipped — status-item width appears fixed from the initial narrow fallback glyph and never grows for the two-segment content. Reproduced consistently across light/dark + low/high load. Not fixed (verification gate). Live-update itself works (7%→8%→10%→19% under load). **Recommend a follow-up fix before final sign-off.** *(Housekeeping from worker: test bundle's `CFBundleExecutable` temporarily renamed to `MRMTestBuild` to disambiguate from a pre-existing Xcode debug build — gitignored dist artifact, overwritten by next `make-dmg.sh`; appearance + login-item left as originally found.)*

**2026-07-17 19:53** — **M6-A (#10 kill + #11 search) done** (Worker, Opus, 5 min, commit `d8d3e3a`). #10: right-click context menu on leaf + group rows, Quit=SIGTERM / Force Quit=SIGKILL (confirmed), `kill()` errors surfaced via alert, grouped rows signal all child PIDs with count in the label, rows self-remove next tick. #11: search field in ProcessListView's own header, live name (case-insensitive) + PID match via pure `ProcessSearchFilter.apply`, composes with profile filter + grouping; 7 new unit tests. Only 2 files touched (ProcessListView + new test) — clean isolation. Build clean, **27/27 green**, tree clean. **All 4 selected M6 features (#10,#11,#12,#13) now shipped; #14,#15 deliberately skipped. T4 (hands-on) dispatched to close out.**

**2026-07-17 19:39** — **M5 gap-fill (processLoad preset) done** (Worker, Sonnet, 1 min, commit `6f23707`). Added `MetricSeverity.processLoad` (warning 40, critical 80) and routed `processCPUColor` (per-row + group-header) through it; `.utilization`/`.capacity` and all gauge consumers untouched. Build clean, 16/16 green. Closes T3's process-row sensitivity finding. **M6-B (#12 live menu-bar icon + #13 Settings scene) done** (Worker, Opus, 3 min, commit `fcd2a63`). #12: `MenuBarLabel` live CPU%/GPU% on the 2s tick, no new timer. #13: real `Settings` scene + new `SettingsView` (General: launch-at-login via `SMAppService`, GPU-core override; Widgets: migrated visibility toggles); slider popover removed; GPU override resolved concurrency-safely by reading `UserDefaults` inside `GPUCollector.collect()` on the engine actor (`resolveCoreCount`: override>0 → reported>0 → tier default). Added 4 override tests → **20/20 green**, clean build, tree clean. Both commits disjoint — no collision. **M6-A (#10 kill + #11 search) released now that gap-fill freed `ProcessListView.swift`.**

**2026-07-17 (decisions)** — User signed off M3 smoothness (T2 gate closed). Approved T3's process-row finding → **gap-fill dispatched** to add a `MetricSeverity.processLoad` preset (warning 40, critical 80) for the process list only, leaving the unified 70/90 gauges intact. Chose to pursue a **subset of M6** stretch features (selection pending). GB-truncation note parked on the M6 backlog.

**2026-07-17 19:19** — **T2 (Test: refactor + M4 regression) done** (Worker, Sonnet, 8 min, commit `564ed08`). Added 8 tests (3 memory clamp via new `clampedFreeBytes` seam, 2 PID-reuse via `ProcessIdentity`→internal, 3 GPU via new `parseAcceleratorStats` seam) — all behavior-neutral extractions. Suite now **16 tests, 0 failures** (orchestrator re-ran). Delta-value sanity check passed (CPU/Disk/Network/GPU rates all change sensibly across samples on the background engine). GPU-card light+dark screenshots confirm QA #6/#7 (80 cores / M3 Ultra) end-to-end. **Smoothness:** worker reports smooth via a CPU-sampling proxy (flat 2.6–3.0% over 8 ticks, no tick-correlated spikes) — the literal scroll/tab test was blocked by screen contention with the concurrent T3 worker, so **final visual smoothness confirmation is recommended from the user.** **T3 (Design Screenshot Review) done** (Worker, Opus, 15 min, no commit — screenshots gitignored, scratch harness reverted, tree clean). 18 shots (light+dark) drove normal/warning/critical via an uncommitted injector. M5 approved: unified severity + colorblind glyphs (dot/triangle/octagon), sparkline scale labels (proven necessary by flat-low/flat-high pair), headline hierarchy — all good in both appearances. **Closes the deferred T1 dark-mode pass.** **Two follow-ups flagged (user's call, not fixed):** (1) process-row thresholds 40/80→70/90 read as too insensitive (Slack 55% / Spotify 42% now uncolored) — recommend a `MetricSeverity.processLoad` preset (warning 40, critical 80) routing only `processCPUColor`, leaving the unified gauges intact; (2) minor — Actual (GB) mode truncates the ring-gauge hero in span-1 grid cards (pre-existing, M6 backlog candidate). **Orchestration lesson:** don't run two GUI-driving workers concurrently on one machine — they contended for window focus. **Core plan (M1–M5 + T1–T3) complete; only optional M6 remains.**

**2026-07-17 19:07** — **M3 (Off-Main Collection Refactor) done** (Worker, Opus, 3 min, commit `83eaf45`). New `CollectionEngine` actor owns all 9 synchronous collectors and runs the per-tick `collect()` off-main; `MetricsManager` (`@MainActor`) now only `await`s the assembled `SystemSnapshot` and does the `@Published` assignment + `history.append`. Isolation model: confine every stateful collector to the single engine actor (no per-collector actors) so `previous*` delta state stays race-free; `LMStudioCollector` (already an actor from M4) `await`ed via `async let`. `isCollecting` reentrancy guard drops overlapping ticks; 2s cadence preserved. `IOReportBridge`'s 100ms `Thread.sleep` now off-main. Verified: only 2 Services files changed (no Views/Models), clean build, `swift test` 8/0 green, `--sanitize=thread` ~12s run → 0 data races. **Perceptual smoothness gate deferred to T2 (hands-on).** T2 now unblocked (M3+M4 done). *(Minor note carried to T2: IOReport sleep now occupies a cooperative-pool thread for 100ms/tick — off-main and fine at 2s, could go async later if desired.)*

**2026-07-17 18:50** — **T1 (Test: collectors + UI screenshots) done — accepted** (Worker, Sonnet, 36 min, commit `0284c98`). Added `MacResourceMonitorTests` XCTest target; 8 tests green (QA #2 unsigned-tick, QA #5 wrap-guard, QA #4 unaligned network parse at a forced non-8-byte offset, + smoke). Tests use additive internal-only seams (`unsignedTicks`, `tickDelta`, `parseIFList2Buffer`) — behavior-neutral, safe for M3. Orchestrator re-ran `swift test` → 8/0. Four light-mode screenshots reviewed: all five M1 fixes confirmed (GPU icon, LM Studio "Connected", 1.91 GHz freq + GHz tooltip, thermal sparkline dropped, About 1.1.0); composite also corroborates M4 (80 cores/M3 Ultra) and M5 (Disk split, GB subtitle, sparkline scale labels). **Dark-mode screenshots skipped** per user direction; user accepted as-is — T3 covers the full dark-mode design pass. Confirmed **no duplicate T1 commit** from the concurrent Opus session that briefly picked up the same prompt. **M3 now unblocked.**

**2026-07-17 18:12** — **M4 (Remaining QA) done** (Worker, Sonnet, 3 min, commit `37162d9`). QA #6 primary-accelerator lock + `as? NSNumber` reads; QA #7 per-chip table (M1–M4) + Ultra/Max/Pro/base tier fallback; QA #8 memory `freeBytes` clamp; QA #9 `LMStudioCollector` → `actor`; QA #10 `ProcessIdentity` (pid+start-time) key. Clean build. Verified in source. **↳ M3 note:** LMStudioCollector is now an actor — M3's off-main refactor must account for that (already `await`-called, so compatible). **M5 (Design Quick Wins) done** (Worker, Opus, 9 min, commit `e55a194`). New `MetricSeverity` unifies severity across menu bar/cards/process rows/disk (#5); colorblind-safe glyphs (#6); headline subtitle hierarchy bump (#7); sparkline min/max scale labels (#8); Disk card split into Disk + new `.diskIO` widget (#9). Clean build; light/dark preserved. Verified in source. **↳ T3 note:** process-row thresholds moved 40/80 → 70/90 for unification (fewer rows colorize) — confirm this is the desired read during design sign-off. Combined M1/M2/M4/M5 tree builds clean. **M3 now needs only T1** to unblock.

**2026-07-17 17:51** — **M1 (Visible UI Bugs) done** (Worker 1, Sonnet, 3 min, commit `c9b7314`). All 5 UI bugs fixed: menu-bar GPU icon → `rectangle.3.group`; LM Studio status reads `snapshot.lmStudio.status`; Thermal sparkline dropped (no numeric series exists); Frequency sparkline now plots GHz via new `pcpuFrequencyHistory` helper; About panel reads `CFBundleShortVersionString`. Clean build, 0 warnings. Verified all edits in source. **M2 (Crash-Class & Leaks) done** (Worker 2, Opus, 2 min, commit `9478f93`). QA #2 unsigned tick casts, QA #5 wrap guard, QA #4 NetworkCollector refactored to in-closure `loadUnaligned` reads, QA #3 host port cached in CPU/Memory collectors. Clean build; ~8s run, no trap. Verified all edits in source. Combined tree builds clean. **T1 now unblocked** (both M1+M2 landed); M4 (needs M2) and M5 (needs M1) also unblocked.

**2026-07-17 (creation)** — Plan generated from `fable-review-july-17.md`. Mapped all 10 QA findings and 15 design recommendations to milestones M1–M6 with incremental testing gates T1–T4. Spot-verified live line references against source: confirmed `MenuBarView.swift:46` `"gpu"` icon and `:73` hardcoded `"Not Connected"`; confirmed About panel `"0.1.0"` string in `MacResourceMonitorApp.swift`; confirmed the signed-`Int32` tick reads and unguarded `UInt64` deltas in `CPUCollector.swift`. No database in project → Schema Review milestone omitted. No web UI → Playwright omitted; visual sign-off is screenshot review of native windows. Sequenced crash-class/leak work (M2) ahead of the threading refactor (M3) so the refactor builds on verified-correct collectors.

[Return to Top](#table-of-contents)

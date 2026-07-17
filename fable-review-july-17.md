# Mac Resource Monitor — QA & Design Review (July 17, 2026)

One-pass review of the app: QA/correctness sweep of the collectors and services, design/usability sweep of the views, plus the app icon redesign. Top findings were spot-verified against the source.

## App icon (done)

The old icon filled the full 1024px canvas. Apple's icon grid insets the artwork squircle to 824/1024 with transparent margin, and the Dock renders icons at face value, so the full-bleed icon looked ~25% larger than every neighbor.

Fixed in commit `5b8ebdb`:

- New generator `scripts/draw-app-icon.swift` renders every iconset size from vector code (16/32px stay crisp instead of being downscaled mush) and builds `src/Resources/AppIcon.icns` via `iconutil`.
- Proper 824/1024 inset, transparent margin, baked drop shadow per Apple's template style.
- Redesigned mark: severity-ramp gauge dial (green → yellow → orange, matching the in-app ring gauges) with white needle on a dark slate squircle.
- The Dock picks it up on the next `scripts/make-dmg.sh` build; `dist/` was left untouched since that bundle is signed and stapled.

## QA findings (ranked)

### High

1. **All synchronous collectors run on the main thread, and PowerCollector sleeps there.** `MetricsManager` is `@MainActor` and calls every collector synchronously (`MetricsManager.swift:86-94`). `IOReportBridge.sampleDelta` does `Thread.sleep` for 100ms (`IOReportBridge.swift:161`), blocking the UI thread every 2s tick. `ProcessCollector` also enumerates every PID with multiple syscalls each on that same thread. Result: recurring scroll/animation stutter. Fix: run collection off the main actor and hop back only for the final `@Published` assignment.

### Medium

2. **CPU tick cast will eventually crash the app.** `host_processor_info` returns signed `Int32` ticks, but the counters are really unsigned. Once a per-core counter passes 2^31 it reads negative, and `UInt64(info[...])` at `CPUCollector.swift:39-42` traps. Idle ticks at ~100Hz cross that in roughly 248 days of core uptime — plausible for an always-on Mac Studio. Fix: `UInt64(UInt32(bitPattern: info[...]))`.

3. **`mach_host_self()` port right leaked every cycle.** `CPUCollector.swift:14` and `MemoryCollector.swift:24` call it every 2s and never `mach_port_deallocate`, so the port ref count grows unbounded — notable for a 24/7 monitor. Fix: cache the host port once.

4. **NetworkCollector loads structs through an escaped, possibly misaligned pointer.** `NetworkCollector.swift:94-105` returns a raw pointer out of `withUnsafeBufferPointer` (undefined behavior once the closure ends), then does typed `load(as: if_msghdr2.self)` at offsets with no 8-byte alignment guarantee — a latent crash. Fix: stay inside the closure and use `loadUnaligned`.

5. **CPU delta underflow on tick wraparound.** Even with #2 fixed, `currentTicks - prev` (`CPUCollector.swift:58-61`) is unguarded `UInt64` subtraction; a 32-bit counter wrap produces one garbage spike sample. Disk/Network guard this with `>=` checks; CPU should too.

6. **GPUCollector multi-accelerator and bridging issues.** The IOAccelerator loop lets the last-enumerated node win (`GPUCollector.swift:20-51`), and core count uses `as? Int` while utilization correctly uses `as? NSNumber` — IORegistry ints bridge as NSNumber, so the `as? Int` can silently fail and fall through to the hardcoded default.

### Low

7. **Core-count fallbacks break on future chips.** Unlisted chips get GPU core count 0; M3 Ultra 80 and Ultra ANE 32 are hardcoded (`GPUCollector.swift:83-101`). Gauges can read 0 or wrong on M4/M5 hardware.

8. **Memory `freeBytes` can underflow.** `totalBytes - usedBytes` (`MemoryCollector.swift:48`) has no clamp; a transient over-sum shows multi-exabyte "free". Clamp with subtraction guard.

9. **LMStudioCollector.latest written off-thread with no synchronization** (`LMStudioCollector.swift:9,23`). Harmless today because only the return value is used, but a race for any future reader.

10. **Process CPU% can glitch on PID reuse.** `previousCPUTimes` keys by PID (`ProcessCollector.swift:39-42`); a recycled PID diffs the new process against the dead one for one sample.

**Verified clean:** sleep/wake rate handling (counter-reset guards, real-elapsed divisors), backward clock changes, and IOReportBridge CF refcount balance are all sound.

## Design & usability recommendations

### Bugs that undercut polish (all quick fixes)

1. **Menu bar GPU icon renders blank** — `MenuBarView.swift:46` uses `"gpu"`, which is not an SF Symbol. The dashboard uses `"rectangle.3.group"` (`DashboardView.swift:419`); match it.
2. **Menu bar LM Studio status is hardcoded to "Not Connected"** (`MenuBarView.swift:73`), ignoring `snapshot.lmStudio`. The dashboard reads real status — the popover line is wrong exactly when it matters.
3. **Thermal and Frequency cards plot the wrong data.** Thermal's sparkline is GPU utilization (`DashboardView.swift:588`); the Frequency card (GHz) plots watts with a `"%.2f W"` formatter (`:561-564`), so hovering "1.46 GHz" shows "0.20 W". Plot the card's own metric or drop the sparkline.
4. **About panel says v0.1.0** (`MacResourceMonitorApp.swift:21`) vs the v1.1.0 release.

### Quick wins

5. **Standardize severity colors/thresholds.** Menu bar uses green/yellow/red at 50/80, cards green/orange/red at 70/90, process rows 40/80, disk 80/95. Same "warning" state, three different looks — centralize on one `MetricSeverity`.
6. **Severity is color-only.** On Network/Thermal/Power cards the sole state cue is a 6px colored dot (`MetricCardView.swift:47`) — not colorblind-safe. Pair color with a shape or SF Symbol.
7. **The headline number is the wrong one for your use case.** In %-mode, memory shows "19%" big and "96.6 / 512 GB" in 10pt tertiary (`MetricCardView.swift:71-74`). When watching unified-memory headroom during inference, GB is the number — bump its contrast or default the Local Inference profile to Actual mode.
8. **Auto-ranged sparklines have no scale** (`SparklineView.swift:42-44`) — flat-low and flat-high look identical. Add a small max/current label.
9. **Disk card mixes capacity % (gauge) with I/O MB/s (sparkline/value)** (`DashboardView.swift:445-483`) — two unrelated metrics in one card; split or pick one.

### Bigger ideas

10. **Process kill/quit action** — the most-expected missing feature vs Activity Monitor/iStat/Stats; add a context menu.
11. **Live process search field** — filtering today is profile-driven substring only (`DashboardLayout.swift:61`).
12. **Live menu bar icon** — the static gauge (`MacResourceMonitorApp.swift:27`) wastes the main reason people run a bar monitor; render live CPU/GPU/mem text or mini-graph in the bar.
13. **Standard Settings scene (⌘,)** for widget visibility, launch-at-login, and a GPU-core-count override, instead of the slider-icon popover (`DashboardView.swift:175`).
14. **Native `Table` for the process list** (`ProcessListView.swift:559` is hand-built HStacks) — worth it when adding selection/kill.
15. **Compact / float-on-top mode** — min size is 860×660 (`DashboardView.swift:120`); no way to shrink to a corner widget.

**What's already strong:** light/dark handling (semantic colors + materials adapt cleanly) and the profile/emphasis two-column dashboard layout.

## Suggested order of attack

1. Design bugs 1–4 (minutes each, all user-visible today)
2. QA #1 (main-thread collection — the one users feel constantly)
3. QA #2/#3/#5 (crash-class, cheap guards)
4. Severity-color unification (design #5) alongside QA #8
5. Then the bigger features: kill action, search, live menu bar

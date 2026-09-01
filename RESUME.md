# Mac Resource Monitor — Resume Prompt

## Project Overview

Native SwiftUI macOS app (bundle ID `com.mikejoseph.mac-resource-monitor`) that consolidates
system resource monitoring (CPU/GPU/memory/disk/network/thermal/power/processes) into one
dashboard, and also runs as a menu-bar extra. Built for a Mac Studio M3 Ultra, macOS 14+,
Swift 5.9, SPM-based (`Package.swift`). Collection runs on a background `CollectionEngine`
actor; `MetricsManager` (`@MainActor`) publishes a `SystemSnapshot` every 2s. The only external
dependency is **Sparkle** (auto-update). See `CLAUDE.md` for architecture + release process.

Release DMGs are **universal (arm64 + x86_64)** — Intel Macs are supported. On Intel, power
(IOReport) is nil, GPU/Neural Engine core counts fall back to 0, and the dashboard shows "—"
for the Neural Engine row.

## Current Status

**v1.4.3 is live in Production and verified end-to-end. This was a one-fix UI session.**

- Fixed: sparkline min/max scale labels were rendering *on top of* the line once a card had a
  full history (the old code assumed an empty left gutter that only exists before history
  accumulates). The plot is now inset by a reserved 36pt axis gutter that the labels own.
- Shipped as **1.4.3** through the full chain. LymeDeploy release 1.4.3 (**id 160**) →
  `Production=succeeded`. Served appcast advertises 1.4.3 / build 8 with edSignature + length
  matching the staged DMG; `cf-cache-status: DYNAMIC`, so **no Cloudflare purge was needed**.
- Verified: `spctl -a -t exec` **accepts** the app inside the shipped DMG; binary is
  `x86_64 arm64`; `CFBundlePackageType = APPL`; DMG serves 200 at 5,018,515 bytes.
- 131 tests green.
- `main` has **8 local commits not yet pushed** (everything back through `9beb49d`) — push
  needs Mike's say-so; he was asked at the end of this session and hadn't answered yet.
- Untracked `dist/MacResourceMonitor.Downloads.1.4.{1,2,3}.nupkg` are pushed-package
  leftovers and can be deleted.

## What's Done

- **Sparkline axis gutter (1.4.3)** — `src/Views/SparklineView.swift`: `gutterWidth = 36`
  (capped at 25% of the card width), `xPositions` offset by the gutter, grid lines start at
  the gutter edge, labels live in a `VStack(alignment: .trailing)` pinned to that column. The
  translucent pill behind each label was dropped — nothing overlaps any more, so it was noise.
- **Universal build (1.4.1)** — `scripts/make-dmg.sh` builds `--arch arm64 --arch x86_64` and
  copies the fat binary from `.build/apple/Products/Release/`. One DMG, one appcast.
- **Intel fallbacks (1.4.1)** — `GPUCollector.neuralEngineCoreCount`/`defaultGPUCoreCount`
  return 0 when `!Architecture.isAppleSilicon`; `DashboardView` shows "—" for a 0 ANE count.
- **Gatekeeper fix (1.4.2)** — `CFBundlePackageType APPL` in `src/Info.plist`. Every release
  before 1.4.2 lacked it and Gatekeeper rejected fresh downloads.
- Earlier sessions: Explore logs / Explore chats browsers (1.4.0), Local AI Storage panel,
  131-test suite.

## What's Next

1. **Push `main`** once Mike okays it (8 unpushed commits).
2. **Confirm on the i5** (carried over from the Intel session): re-download the current DMG,
   launch, sanity-check the dashboard on Intel — power card absent, Neural Engine "—", GPU
   util may be blank depending on what Intel IOAccelerator reports. **Nobody has eyeballed
   this yet.**
3. **Add a release-config build to your definition of green** (carried over): `swift build`
   and `swift test` are debug-only; release breakage has surfaced mid-release before. Also
   worth folding a `spctl -a -t exec` check of the staged app into `make-dmg.sh` — the
   Gatekeeper defect shipped unnoticed in every release before 1.4.2.
4. **Optional follow-ups** (none blocking): distinguish failed walks from empty in
   `AIStorageModel.listFiles`; LM Studio `preview.data` thumbnails decode full-size PNGs;
   `SUFeedURL` points at `iadev.net` which 301s to `www.iadev.net` (deliberate, baked into
   shipped copies).

## Planning Docs

- `BACKLOG.md` — next big item is **customizable dashboard layouts** (drag-reorder,
  per-widget column span, saved scenarios), to grow out of `DashboardLayout`.
- `local-llm-history-browser.md` — Explore Logs execution plan, **all milestones complete**;
  its Progress Log is the detailed 1.4.0 history.
- `chat-history-viewer-prompt.md` — brief that built the chat viewer; carries the surveyed
  LM Studio JSON shapes.
- `PLANNING.md`, `fable-review-remediation-plan.md`, `fable-review-july-17.md` — earlier,
  completed work.

## Key File Paths

```
src/Info.plist                          SINGLE SOURCE OF TRUTH: version, SU* keys,
                                        CFBundlePackageType (bump BOTH version keys per release)
src/Views/SparklineView.swift           graph + axis gutter (1.4.3 fix lives here)
src/Views/MetricCardView.swift          the only SparklineView call site
src/Services/Architecture.swift         isAppleSilicon (hw.optional.arm64)
src/Services/GPUCollector.swift         Intel-aware core-count/ANE fallbacks
src/Services/PowerCollector.swift       returns nil on Intel (IOReport unavailable)
src/Services/AIStorageCollector.swift   actor: scan/search/purge + file readers
src/Views/AIStorage*.swift              Local AI Storage panel + browsers
scripts/make-dmg.sh                     universal build → sign → notarize → staple
scripts/stage-release.sh                EdDSA-sign + rewrite appcast → dist/upload/
deploy/pack-for-lymedeploy.sh           pack dist/upload/ → .nupkg → push to LymeDeploy
deploy/updates/appcast.xml              title + <description> hand-written; rest rewritten
                                        by stage-release.sh
Tests/MacResourceMonitorTests/          131 tests
```

## Recent Git Log

```
5d24afd Release 1.4.3: sparkline scale labels get their own axis gutter
0c8bbb5 Give sparklines a left axis gutter so scale labels don't overlap the line
916e4fc Update resume prompt for the 1.4.1/1.4.2 Intel-support releases
4dd2b81 Release 1.4.2: declare CFBundlePackageType so Gatekeeper accepts the app
5b15ad1 Release 1.4.1: universal binary with Intel Mac support
91a36d1 Ship a universal (arm64 + x86_64) DMG so Intel Macs can run the app
9f6b8d3 Mark 1.4.0 as live in the resume prompt
9beb49d Update resume prompt for the 1.4.0 release
```

## Any Other Notes

- **Build/run:** `swift build` · `swift build -c release` · `swift test` ·
  `swift run MacResourceMonitor`. Universal check: `swift build -c release --arch arm64
  --arch x86_64`, then `lipo -archs .build/apple/Products/Release/MacResourceMonitor`.
- **Release (the exact chain used for 1.4.3):** bump **both** version keys in
  `src/Info.plist`, hand-write the appcast `<title>` + `<description>`, then

  ```
  SIGN_ID="Developer ID Application: INTERAPP DEVELOPMENT, INC. (UU626VCLYW)" \
  NOTARIZE_PROFILE="mrm-notary" ./scripts/make-dmg.sh
  ./scripts/stage-release.sh
  ./deploy/pack-for-lymedeploy.sh
  lymedeploy create-release --project mac-resource-monitor-downloads --version X \
    --package MacResourceMonitor.Downloads=X --deploy-to Production
  lymedeploy status --project mac-resource-monitor-downloads
  ```

  EdDSA private key lives in the login Keychain, never in the repo. The LymeDeploy project
  slug is **`mac-resource-monitor-downloads`** (not `mac-resource-monitor`).
- **Post-deploy verification worth repeating:** `curl -s -L
  https://iadev.net/mac-resource-monitor/appcast.xml` and check version/length/edSignature
  against the staged DMG, plus the `cf-cache-status` header to see whether a Cloudflare purge
  is actually needed.
- **Gotcha — Gatekeeper verification:** `stapler validate` and `codesign --verify` both
  passing is NOT enough; only `spctl -a -t exec` catches "does not seem to be an app"
  (missing `CFBundlePackageType`). Assess the app *inside the mounted DMG*.
- **Gotcha — piping release scripts:** `./scripts/make-dmg.sh | tail` reports *tail's* exit
  code. Use `set -o pipefail` or don't pipe.
- **Gotcha — filesystem tests:** plant fixture roots under `.build/`, never `/tmp` or
  `/var/folders` (the `/private` symlink makes `resolvingSymlinksInPath()` disagree with
  the enumerator and the root guard fails spuriously).
- **Real data scale on this machine:** `~/.lmstudio/server-logs` ~29 GB / ~3080 files;
  `~/.omlx/cache` ~148 GB. Anything walking these must be lazy and cancellable.

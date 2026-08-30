# Mac Resource Monitor — Resume Prompt

## Project Overview

Native SwiftUI macOS app (bundle ID `com.mikejoseph.mac-resource-monitor`) that consolidates
system resource monitoring (CPU/GPU/memory/disk/network/thermal/power/processes) into one
dashboard, and also runs as a menu-bar extra. Built for a Mac Studio M3 Ultra, macOS 14+,
Swift 5.9, SPM-based (`Package.swift`). Collection runs on a background `CollectionEngine`
actor; `MetricsManager` (`@MainActor`) publishes a `SystemSnapshot` every 2s. The only external
dependency is **Sparkle** (auto-update). See `CLAUDE.md` for architecture + release process.

As of 1.4.1 release DMGs are **universal (arm64 + x86_64)** — Intel Macs are supported. On
Intel, power (IOReport) is nil, GPU/Neural Engine core counts fall back to 0, and the
dashboard shows "—" for the Neural Engine row.

## Current Status

**v1.4.2 is live in production, verified end-to-end, and this was the Intel-support session.**

- This session shipped **two releases**:
  - **1.4.1** — universal binary (arm64 + x86_64) so an Intel i5 Mac on Sequoia can run it.
  - **1.4.2** — added the missing `CFBundlePackageType = APPL` to `src/Info.plist`.
    **Every prior release lacked it**, so Gatekeeper rejected fresh downloads with
    "Apple could not verify… free of malware" (spctl: "does not seem to be an app").
    It never surfaced on the Studio because installs there never hit Gatekeeper quarantine.
- Verified: `spctl -a -t exec` **accepts** the app inside the shipped 1.4.2 DMG; binary is
  `x86_64 arm64`; LymeDeploy release 1.4.2 (id 141) → `Production=succeeded`; served appcast
  advertises 1.4.2 with edSignature/length matching the staged DMG.
- `main` has **local commits not yet pushed** (`91a36d1`, `5b15ad1`, `4dd2b81`) — push needs
  Mike's say-so.
- The i5 still needs a manual re-download of the 1.4.2 DMG (its 1.4.1 copy predates the fix).
- Untracked pushed-package artifacts `dist/MacResourceMonitor.Downloads.1.4.{1,2}.nupkg` can
  be deleted.

## What's Done

- **Universal build** — `scripts/make-dmg.sh` builds `--arch arm64 --arch x86_64` and copies
  the fat binary from `.build/apple/Products/Release/`. One DMG, one appcast; no LymeDeploy
  changes were needed.
- **Intel fallbacks** — `GPUCollector.neuralEngineCoreCount`/`defaultGPUCoreCount` return 0
  when `!Architecture.isAppleSilicon` instead of fabricating Apple Silicon values;
  `DashboardView` shows "—" for a 0 Neural Engine count.
- **Gatekeeper fix** — `CFBundlePackageType APPL` added to `src/Info.plist` (1.4.2).
- **Releases 1.4.1 + 1.4.2** — full chain both times: version keys bumped, appcast notes
  hand-written, `make-dmg.sh` (sign/notarize/staple) → `stage-release.sh` →
  `pack-for-lymedeploy.sh` → `lymedeploy create-release --deploy-to Production`.
- Earlier sessions: Explore logs / Explore chats browsers (1.4.0), Local AI Storage panel,
  131-test suite.

## What's Next

1. **Confirm on the i5**: re-download `MacResourceMonitor-v1.4.2.dmg`, launch, sanity-check
   the dashboard on Intel (power card absent, Neural Engine "—", GPU util may be blank
   depending on what Intel IOAccelerator reports — nobody has eyeballed it yet).
2. **Push `main`** once Mike okays it (3 unpushed release commits).
3. **Add a release-config build to your definition of green** (carried over): `swift build`
   and `swift test` are debug-only; release breakage has surfaced mid-release before. Now
   also worth a `spctl -a -t exec` check of the staged app in `make-dmg.sh` — the
   Gatekeeper defect shipped in every release before 1.4.2 unnoticed.
4. **Optional follow-ups** (none blocking): distinguish failed walks from empty in
   `AIStorageModel.listFiles`; LM Studio `preview.data` thumbnails decode full-size PNGs;
   `SUFeedURL` points at `iadev.net` which 301s to `www.iadev.net` (deliberate, baked into
   shipped copies).

## Planning Docs

- `local-llm-history-browser.md` — Explore Logs execution plan, **all milestones complete**;
  its Progress Log is the detailed 1.4.0 history.
- `chat-history-viewer-prompt.md` — brief that built the chat viewer; carries the surveyed
  LM Studio JSON shapes.
- `PLANNING.md`, `fable-review-remediation-plan.md`, `fable-review-july-17.md` — earlier,
  completed work.
- `BACKLOG.md` — next big item is **customizable dashboard layouts** (drag-reorder,
  per-widget column span, saved scenarios), to grow out of `DashboardLayout`.

## Key File Paths

```
src/Info.plist                          SINGLE SOURCE OF TRUTH: version, SU* keys, and now
                                        CFBundlePackageType (bump BOTH version keys per release)
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
4dd2b81 Release 1.4.2: declare CFBundlePackageType so Gatekeeper accepts the app
5b15ad1 Release 1.4.1: universal binary with Intel Mac support
91a36d1 Ship a universal (arm64 + x86_64) DMG so Intel Macs can run the app
9f6b8d3 Mark 1.4.0 as live in the resume prompt
9beb49d Update resume prompt for the 1.4.0 release
a964b3e Refresh appcast for the 1.4.0 release
fb5d04b Gate the AI storage previews behind DEBUG so release builds compile
835dcb3 Bump to 1.4.0 for the Explore logs and Explore chats browsers
```

## Any Other Notes

- **Build/run:** `swift build` · `swift build -c release` · `swift test` ·
  `swift run MacResourceMonitor`. Universal check: `swift build -c release --arch arm64
  --arch x86_64`, then `lipo -archs .build/apple/Products/Release/MacResourceMonitor`.
- **Release:** bump **both** version keys in `src/Info.plist`, hand-write the appcast
  `<title>` + `<description>`, then `make-dmg.sh` → `stage-release.sh` →
  `pack-for-lymedeploy.sh` → `lymedeploy create-release --project
  mac-resource-monitor-downloads --version X --package MacResourceMonitor.Downloads=X
  --deploy-to Production`. `make-dmg.sh` needs
  `SIGN_ID="Developer ID Application: INTERAPP DEVELOPMENT, INC. (UU626VCLYW)"` and
  `NOTARIZE_PROFILE="mrm-notary"`. EdDSA private key lives in the login Keychain, never
  in the repo. The LymeDeploy project slug is **`mac-resource-monitor-downloads`** (not
  `mac-resource-monitor` — probe with `lymedeploy status`).
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

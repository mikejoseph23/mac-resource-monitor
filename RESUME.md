# Mac Resource Monitor — Resume Prompt

## Project Overview

Native SwiftUI macOS app (bundle ID `com.mikejoseph.mac-resource-monitor`) that consolidates
system resource monitoring (CPU/GPU/memory/disk/network/thermal/power/processes) into one
dashboard, and also runs as a menu-bar extra. Built for a Mac Studio M3 Ultra, macOS 14+,
Swift 5.9, SPM-based (`Package.swift`). Collection runs on a background `CollectionEngine`
actor; `MetricsManager` (`@MainActor`) publishes a `SystemSnapshot` every 2s. The only external
dependency is **Sparkle** (auto-update). See `CLAUDE.md` for architecture + release process.

The **Local AI Storage** panel is its own subsystem: `AIStorageCollector` (an `actor`) scans
what LM Studio and oMLX retain on disk, deliberately off the 2s tick — its own cadence, a
5-minute floor, every scan cancellable and off the main actor.

## Current Status

**v1.4.0 is live in production and verified — a real 1.3.0 install auto-updated to it.**

- Two read-only browsers shipped this session: **Explore logs** and **Explore chats**.
- `main` is pushed through `a964b3e`. `swift build` clean (debug **and** release), `swift test`
  **131 tests, 0 failures**.
- LymeDeploy release 1.4.0 (id 102) → `Production=succeeded`. The served appcast advertises
  1.4.0 / `sparkle:version=5` with an `edSignature` and `length` byte-identical to the staged DMG.
  No Cloudflare purge was needed — the appcast returns `cf-cache-status: DYNAMIC`.
- **Nothing is blocked.** The next piece of work is free choice; see What's Next.
- Untracked artifact `dist/MacResourceMonitor.Downloads.1.4.0.nupkg` is the pushed package and can
  be deleted. (`dist/upload/` is gitignored; this filename isn't.)
- Visual sign-off of the new sheets was done by hand and never captured; no screenshot suite exists.

## What's Done

- **Explore logs** (`AIStorageLogsSheet`) — read-only browser over `~/.lmstudio/server-logs`,
  `~/.lmstudio/conversations`, `~/.omlx/logs`. Month-sectioned newest-first list with an
  All/30-day/7-day filter, SF Mono viewer, tail-first open (256 KB) with **byte-window paging**
  backwards on scroll-up, raw/pretty JSON toggle, Reveal in Finder, directory watcher that
  re-lists on change, full VoiceOver + keyboard (arrows move a cursor ring, Return opens).
- **Explore chats** (`AIStorageChatsSheet` + `AIStorageChatParser`) — LM Studio GUI conversations
  rendered as transcripts: roles, reasoning blocks collapsed by default, `debugInfoBlock` tucked
  away, images inline (260×220) and click-to-enlarge (720×560).
- **Read-only guarantees** — every path passes `AIStoragePathGuard.isReadable` after symlink
  resolution; no write/delete/move API exists in either browser; neither triggers `rescan()`.
- **Panel actions consolidated** into one ellipsis menu in the card header plus a right-click
  context menu, with Purge divided off and marked `.destructive`.
- **Release 1.4.0** — version bumped (`CFBundleShortVersionString` 1.4.0 / `CFBundleVersion` 5),
  DMG signed + notarized + stapled, EdDSA signature verified against the staged DMG, appcast
  release notes written, package pushed to LymeDeploy.
- Test suite grew 35 → 131 (pure helpers, filesystem integration against an injectable root,
  chat parsing).

## What's Next

1. **Add a release-config build to your definition of green.** Release builds were silently broken
   from `31be0fb` until `fb5d04b` this session: three `#Preview` blocks referenced the
   `#if DEBUG`-gated `AIStorageSnapshot.preview` without being gated themselves. `swift build` and
   `swift test` are both debug, so nothing caught it — it only surfaced mid-release. Run
   `swift build -c release` in CI or pre-commit.
2. **Optional follow-ups** (none blocking):
   - `AIStorageModel.listFiles` collapses errors *and* `CancellationError` into `[]` via `try?`,
     so a genuinely failed walk renders as "No files here". Worth distinguishing.
   - LM Studio's image sidecar `preview.data` is full-size bytes, not a downscale, so every
     thumbnail decodes a full PNG. Invisible at 3 images; would matter at hundreds.
   - The oMLX **Vision features** purge target's description says what the files are but not that
     they're a re-derivable cache — the fact that makes the checkbox safe to tick.
   - `SUFeedURL` in `src/Info.plist` points at `iadev.net`, which 301-redirects to `www.iadev.net`.
     Sparkle follows it, but every client pays an extra round trip on every update check. Changing
     it is deliberate — the feed URL is baked into every shipped copy.
   - Reconstructing agentic/API conversations from `server-logs` was explicitly ruled out of
     scope: that traffic never reaches `conversations/`, and long bodies are elided as
     `<Truncated in logs>`, so it is lossy by nature. Best-effort only if you ever want it.

## Planning Docs

- `local-llm-history-browser.md` — the Explore Logs execution plan. **All milestones complete**
  (M1–M4, T1/T2/T4); T3 (screenshot + hands-on) was deliberately skipped in favour of manual
  sign-off. Its Progress Log is the detailed history of this session.
- `chat-history-viewer-prompt.md` — the self-contained brief that built the chat viewer. Carries
  the surveyed LM Studio conversation/image JSON shapes; useful reference if you extend it.
- `PLANNING.md`, `fable-review-remediation-plan.md`, `fable-review-july-17.md` — earlier,
  completed work.
- `BACKLOG.md` — next big item is **customizable dashboard layouts** (drag-reorder, per-widget
  column span, saved scenarios), to grow out of `DashboardLayout`.

## Key File Paths

```
src/Models/SystemMetrics.swift          AIStorageTarget/Snapshot/FileEntry + #if DEBUG fixtures
src/Services/
  AIStorageCollector.swift              actor: scan/search/purge + listFiles/readTail/readWindow/
                                        readFull; injectable `root:`; AIStoragePathGuard,
                                        AIStorageLogLayout, AIStorageTailReader live here
  AIStorageChatParser.swift             pure conversation JSON → transcript view models
  AIStorageModel.swift                  @MainActor wrappers, AIStorageFileContent (.ok/.denied/
                                        .missingFile), own 5-min cadence
src/Views/
  AIStoragePanelView.swift              the card + the consolidated action menu
  AIStorageLogsSheet.swift              log browser (windowed paging, dir watcher)
  AIStorageChatsSheet.swift             chat transcript viewer
  AIStorageSearchSheet.swift            "is my secret in here?" — paths + counts only
  AIStoragePurgeSheet.swift             the only destructive surface — invariant: the destructive
                                        control must not move under the pointer
Tests/MacResourceMonitorTests/          131 tests; AIStorage* are this session's
src/Info.plist                          SINGLE SOURCE OF TRUTH for version + SU* keys
scripts/make-dmg.sh                     build → sign → notarize → staple
scripts/stage-release.sh                EdDSA-sign + rewrite appcast → dist/upload/
deploy/pack-for-lymedeploy.sh           pack dist/upload/ → .nupkg → push to LymeDeploy
deploy/updates/appcast.xml              title + <description> are hand-written; everything else
                                        is rewritten by stage-release.sh
```

## Recent Git Log

```
a964b3e Refresh appcast for the 1.4.0 release
fb5d04b Gate the AI storage previews behind DEBUG so release builds compile
835dcb3 Bump to 1.4.0 for the Explore logs and Explore chats browsers
a9dd122 Consolidate the AI storage panel actions into one menu
76ab272 Render LM Studio conversations as readable transcripts
123e8ac Add execution plan for the Explore Logs browser
5ecc60c Page the log browser and finish its accessibility pass
e534fc6 Wire the Explore Logs browser to the real collector read APIs
```

## Any Other Notes

- **Build/run:** `swift build` · `swift build -c release` · `swift test` · `swift run MacResourceMonitor`
- **Release:** bump **both** version keys in `src/Info.plist`, hand-write the appcast `<title>` +
  `<description>`, then `make-dmg.sh` → `stage-release.sh` → `pack-for-lymedeploy.sh`.
  `make-dmg.sh` needs `SIGN_ID="Developer ID Application: INTERAPP DEVELOPMENT, INC. (UU626VCLYW)"`
  and `NOTARIZE_PROFILE="mrm-notary"`. The Sparkle EdDSA private key lives in the login Keychain,
  never in the repo.
- **Gotcha — piping release scripts:** `./scripts/make-dmg.sh | tail` reports *tail's* exit code,
  so a failed build looks like success. Use `set -o pipefail` or don't pipe.
- **Gotcha — filesystem tests:** plant fixture roots under the package's `.build/`, never `/tmp`
  or `/var/folders`. Those sit behind macOS's `/private` symlinks, and
  `URL.resolvingSymlinksInPath()` then disagrees with the directory enumerator's raw paths, which
  makes the root guard fail spuriously.
- **Real data scale on this machine:** `~/.lmstudio/server-logs` is ~29 GB across ~3080 `.log`
  files rotated at ~10 MB; `~/.omlx/cache` is ~148 GB. Anything that walks these must be lazy,
  cancellable, and must never read a whole file eagerly.

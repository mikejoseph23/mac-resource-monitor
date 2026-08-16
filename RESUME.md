# Mac Resource Monitor — Resume Prompt

## Project Overview

Native SwiftUI macOS app (bundle ID `com.mikejoseph.mac-resource-monitor`) that consolidates
system resource monitoring (CPU/GPU/memory/disk/network/thermal/power/processes) into one
dashboard, and also runs as a menu-bar extra. Built for a Mac Studio M3 Ultra, macOS 14+,
Swift 5.9, SPM-based (`Package.swift`). Collection runs on a background `CollectionEngine`
actor; `MetricsManager` (`@MainActor`) publishes a `SystemSnapshot` every 2s. The only external
dependency is **Sparkle** (auto-update). See `CLAUDE.md` for architecture + release process.

## Current Status

**v1.2.1 is shipped, uploaded, and the Sparkle auto-update was tested end-to-end and works.**
Nothing blocked. **5 commits are committed locally on `main` but NOT yet pushed** (`git status`
shows `ahead 5`).

- ✅ v1.2.1 released: notarized + stapled DMG, uploaded to `iadev.net/mac-resource-monitor/`,
  Cloudflare cache purged for `appcast.xml`. **Auto-update verified working** (updated from 1.2.0).
- ✅ Dashboard layout overhaul + Storage Volumes DMG-filter bug fix shipped in 1.2.1.
- ✅ README updated to point at the download site + explain auto-update.
- ⏳ **`git push` is still pending** — 5 unpushed commits (see below). Also tag once pushed:
  `git tag v1.2.1 && git push --tags`.

## What Happened This Session (2026-07-19)

Triggered by a friend (RD) running v1.2.0 on an M5 Pro laptop and sending a screenshot. Fixes:

1. **Storage Volumes bug** — the app's own mounted **DMG** was being listed as a drive.
   `DiskCollector.collectVolumes()` now filters non-physical/system volumes via `URLResourceKey`
   (`.volumeIsBrowsableKey`, `.volumeIsLocalKey`) + a `statfs` mount-flag check
   (`MNT_RDONLY`/`MNT_DONTBROWSE` → excluded); boot volume `/` always kept.
2. **Default dashboard rebalance** — the lone/orphaned Thermal card + dead space are gone;
   Thermal placement is adaptive to card count.
3. **Wider default window** — `900×700` → `1200×840` in `MacResourceMonitorApp.swift`.
4. **Width cap + centering** — content capped at `contentMaxWidth = 1180pt` and centered so wide
   windows get side margins instead of full-bleed sparse panels.
5. **Top grid stretches to match bottom panels** — switched the card grid from a fixed measured
   `unitColumnWidth` to equal-width flexible columns (`equalWidthRow`), killing the "upside-down-T".
6. **Local Inference profile (`twoColumnLayout`)** — reworked from tall stacked columns into
   horizontal bands (hero row Memory/GPU/Power + compact grid + bottom panels), and made cards
   **equal height per row** via an `equalWidthRow(fillHeight:)` flag + a trailing `Spacer` in
   `MetricCardView` (content pins to top, extra height becomes bottom padding; 0-height when not
   stretched, so Default/MenuBar render identically).

All layout changes are in `src/Views/DashboardView.swift` + `src/Views/MetricCardView.swift`;
volume fix in `src/Services/DiskCollector.swift`; window size in `src/MacResourceMonitorApp.swift`.
**35/35 tests pass.**

## Unpushed Commits (on `main`, ahead 5)

```
686426d Update README with download site and auto-update info
536782e Release 1.2.1: dashboard layout polish and Storage Volumes filtering
9924369 Stretch default dashboard card grid to match bottom panel width
e84b77b Stage landing page with release version in stage-release.sh   (from prior session)
b5f7a05 Add landing page for the download folder                       (from prior session)
```

## What's Next

Nothing required. Open items when convenient:

1. **`git push`** the 5 unpushed commits, then `git tag v1.2.1 && git push --tags`.
2. **Parked follow-ups from this session:**
   - Hide/disable "Check for Updates…" in **debug builds** — `swift run` debug builds don't embed
     `Sparkle.framework`, so the menu item throws an "Unable to Check For Updates / updater failed
     to start" dialog on launch. Cosmetic; never happens in the notarized DMG. Gate the menu item
     on a bundled/release build.
   - **`stage-release.sh` should template the appcast `<title>`/`<description>`** — it only rewrites
     the `<enclosure>`; the item title/notes are left as the prior version's text and had to be
     hand-edited this release (title was still "1.2.0").
3. Backlog next-ups (`BACKLOG.md`): customizable dashboard layouts, Ollama support.

## Cutting the Next Release (clean loop; see CLAUDE.md "Auto-update (Sparkle) & Release")

1. Bump **both** `CFBundleShortVersionString` + `CFBundleVersion` in `src/Info.plist`.
2. `SIGN_ID="Developer ID Application: INTERAPP DEVELOPMENT, INC. (UU626VCLYW)" NOTARIZE_PROFILE="mrm-notary" ./scripts/make-dmg.sh`
3. `./scripts/stage-release.sh` (signs DMG + refreshes appcast + stages landing page → `dist/upload/`).
4. Hand-edit the appcast `<title>` + `<description>` release notes (until the script is fixed — see follow-up above).
5. Upload everything in `dist/upload/` to `iadev.net/mac-resource-monitor/`, then **purge the
   Cloudflare cache for `appcast.xml`** (same URL, new content; versioned DMG URLs are fine).
6. Commit the released appcast; `git tag vX.Y.Z && git push --tags`.

## Distribution

- **Website / landing page:** `https://iadev.net/mac-resource-monitor/` (`index.html`).
- **Feed:** `https://iadev.net/mac-resource-monitor/appcast.xml` (`SUFeedURL` in `src/Info.plist`).
- **DMG (current):** `https://iadev.net/mac-resource-monitor/MacResourceMonitor-v1.2.1.dmg` (versioned).
- **EdDSA key:** private half in login Keychain (account `ed25519`, shared with LymeScribe —
  Sparkle uses one key across apps); public half is `SUPublicEDKey` in `src/Info.plist`.
- **Notary:** keychain profile `mrm-notary`, team `UU626VCLYW`. Cloudflare fronts `iadev.net`.

## Key File Paths

```
src/
  MacResourceMonitorApp.swift   App entry; MenuBarExtra, Settings, "Check for Updates…"; default 1200x840 window
  Info.plist                    Source of truth: version (1.2.1 / build 3) + Sparkle SU* keys
  Services/
    DiskCollector.swift         collectVolumes() — filters DMG/read-only/non-physical volumes
    UpdaterModel.swift          Wraps SPUStandardUpdaterController (menu + Settings toggle)
    CollectionEngine.swift      Actor owning all collectors, runs collect() off-main
    MetricsManager.swift        @MainActor; awaits engine.collect()
  Views/
    DashboardView.swift         Profiles: uniformGridLayout (Default) + twoColumnLayout (Local Inference); equalWidthRow(fillHeight:), 1180pt cap
    MetricCardView.swift        Card; trailing Spacer(minLength:0) for equal-height rows
    SettingsView.swift          General (updates toggle, launch-at-login, GPU override) + Widgets
scripts/
  make-dmg.sh                   Build → embed/sign Sparkle → laid-out DMG → sign → notarize
  stage-release.sh              EdDSA-sign DMG + refresh appcast + stage dist/upload/  (title/notes still manual)
  draw-dmg-background.swift     DMG background art (600x400 + @2x, LymeScribe-style)
deploy/updates/                 Server mirror: appcast.xml, web.config, index.html, screenshot.png
Tests/MacResourceMonitorTests/  35 tests
dist/                           Build output (upload/ is the staged upload folder; *.dmg gitignored)
```

## Any Other Notes

- **Build/test:** `swift build`, `swift test` (35 green), `swift run MacResourceMonitor`.
- **Sparkle framework:** `swift build` does NOT embed it; `make-dmg.sh` copies it and adds the
  `@executable_path/../Frameworks` rpath. Sign inside-out (XPC → Autoupdate → Updater.app →
  framework → app); no `--deep`. Debug `swift run` builds therefore can't launch the updater.
- **Appcast invariant:** never upload with the placeholder `edSignature`/`length` —
  `stage-release.sh` fills them from the notarized DMG; must match the shipped bytes.
- **Working-tree noise:** `RESUME.md` + `fable-review-remediation-plan.md` are untracked working
  files; `dist/MacResourceMonitor-v1.2.*.dmg` are rebuildable artifacts (gitignored).

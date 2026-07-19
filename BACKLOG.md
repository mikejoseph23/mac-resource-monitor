# Backlog

## Customizable dashboard layouts

Today the dashboard has fixed widget order, fixed column count, and only show/hide
configurability. Take it the rest of the way:

- **Drag to reorder** widgets within the grid (SwiftUI `.draggable` + `.dropDestination`)
- **Per-widget column span** — bootstrap-style 1/2/3 width per card (likely needs a
  custom `Layout` since `LazyVGrid` doesn't support per-cell spans; SwiftUI's `Grid`
  does via `.gridCellColumns(_:)` but is row-based which complicates dynamic visibility)
- **Multiple saved layouts / scenarios** — e.g. "LLM run", "Build machine", "Idle";
  switch via tab bar or menu, each with its own widget set + order + spans
- Persist all of the above to UserDefaults (extend the existing `dashboard.hiddenWidgets` key)

The existing `DashboardLayout` ObservableObject is the right place to grow this —
add `order: [DashboardWidget]` and `span: [DashboardWidget: Int]` (1–3) properties,
keep them codable for round-tripping via JSON in UserDefaults.

## Sparkle-based auto-update — DONE (2026-07-19)

Shipped: Sparkle 2.x embedded via SPM, updater wired in `src/Services/UpdaterModel.swift`
("Check for Updates…" menu item + Settings toggle), feed at
`https://iadev.net/mac-resource-monitor/appcast.xml` (`deploy/updates/appcast.xml`),
`make-dmg.sh` embeds + inside-out-signs the framework, `scripts/stage-release.sh`
EdDSA-signs the DMG and refreshes the appcast. See CLAUDE.md "Auto-update (Sparkle)
& Release". Original notes below for reference.

Add in-app auto-update via [Sparkle](https://sparkle-project.org/) so shipped builds can
update themselves instead of users manually re-downloading the DMG from GitHub Releases.
Model it on the working setup in `~/git/lymescribe` (see its `deploy/updates/appcast.xml`,
`deploy/update-hashes.sh`, and the `SUFeedURL`/`SUPublicEDKey` notes in its `CLAUDE.md`).

- **Add the Sparkle SPM dependency** to `Package.swift` (`github.com/sparkle-project/Sparkle`,
  2.x) and wire a `SPUStandardUpdaterController` into the app (a "Check for Updates…" menu
  item + automatic background checks). Ties naturally into the new **Settings scene** (#13) —
  add an "Automatically check for updates" toggle there.
- **Generate an EdDSA key pair** (`generate_keys` from Sparkle's tools); put the **public**
  key in `Info.plist` as `SUPublicEDKey`, keep the private key in the Keychain (never in the
  repo). Add `SUFeedURL` pointing at the appcast.
- **Host the appcast + DMG.** lymescribe serves its appcast from `iadev.net`; here the DMG
  already lives on **GitHub Releases**, so simplest is an `appcast.xml` served from the repo's
  GitHub Pages (or a raw `gh-pages`/`docs/` URL) with `<enclosure>` URLs pointing at the
  Release DMG asset. Decide feed host as part of this task.
- **Automate the release step.** Extend `scripts/make-dmg.sh` (or add a `stage-release`
  script like lymescribe's) to, after building the notarized DMG: run Sparkle's `sign_update`
  to get the `sparkle:edSignature`, compute the size, and append/refresh the `<item>` in
  `appcast.xml` (version, notes, enclosure url + length + ed signature). Mirror lymescribe's
  invariant: **after any DMG-content change, regenerate the signature/hash — never ship an
  appcast with a stale/placeholder signature.**
- **Requires the version bump discipline below** — Sparkle compares `CFBundleShortVersionString`
  / `CFBundleVersion` against the appcast, so every release must bump both (see "Versioning").

## Versioning discipline (do every release)

Version is tracked in `src/Info.plist` (`CFBundleShortVersionString` marketing version +
`CFBundleVersion` build number), git tags (`vX.Y.Z`), and GitHub Releases. Bump **both**
Info.plist keys, tag, and cut a matching GitHub Release with a fresh DMG on every user-facing
release — the About panel and (future) Sparkle appcast both read these, so they can't drift.
The v1.1.0→next release (today's remediation batch) is the first application of this.

## Ollama support

Detect and surface Ollama alongside (or instead of) LM Studio. Ollama's local API runs at `http://localhost:11434` — `GET /api/ps` returns currently-loaded models with size/VRAM info.

- Auto-detect which provider is running (LM Studio on :1234, Ollama on :11434, or both)
- Show loaded model name + memory footprint in the dashboard card
- Degrade silently when neither is running

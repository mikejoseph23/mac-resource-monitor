# Worker Context: LM Studio Chat History Viewer

You are building one self-contained feature in an existing native macOS SwiftUI app, then
reporting back. Complete it, commit it, write a summary, and stop.

**Repo:** `/Users/michaeljosephwork/git/mac-resource-monitor`
**Branch:** work directly on `main`. Do **not** create a feature branch.
**Baseline:** tip `123e8ac`, `swift build` clean, `swift test` **84 tests, 0 failures**.
Read `CLAUDE.md` in the repo root before you start.

Build: `swift build` · Test: `swift test` · Run: `swift run MacResourceMonitor`

---

## Mission

The app has a **Local AI Storage** panel that scans what LM Studio and oMLX retain on disk, plus a
read-only **Explore logs…** browser for the raw log files. Reading a *chat* through that raw log
viewer is miserable — it's a text dump.

Build a **Chat History viewer**: a read-only browser that renders LM Studio's saved GUI
conversations as actual transcripts — user and assistant turns, collapsible reasoning blocks, and
**inline images** — instead of raw JSON.

**In scope:** LM Studio GUI conversations (`~/.lmstudio/conversations/`) and the images they
reference (`~/.lmstudio/user-files/`).

**Explicitly OUT of scope:** reconstructing agentic/API traffic from `~/.lmstudio/server-logs`.
That traffic never reaches `conversations/` (`.internal/api-prediction-history/packs` is empty), it
survives only as pretty-printed request bodies in the logs, and it's lossy — long content is elided
as `<Truncated in logs>`. It is a separate future feature. **Do not attempt it.** The existing
Explore-logs browser already covers reading those logs raw.

---

## The data shapes — already surveyed for you, do not re-derive

There are **13** files in `~/.lmstudio/conversations/`, ~22 exchanges total. Read a couple yourself
to confirm, but this is the full picture:

### Conversation file: `~/.lmstudio/conversations/<epochMillis>.conversation.json`

Top level keys: `name` (**may be absent/null — fall back to the file's epoch-millis stem as a
date**), `pinned`, `createdAt`, `tokenCount`, `systemPrompt`, `lastUsedModel`, `messages`,
plus config keys you can ignore (`preset`, `plugins`, `perChatPredictionConfig`, …).

`messages[]` — each entry is `{ versions: [...], currentlySelected: Int }`. `versions` holds
**regenerations**; render `versions[currentlySelected]` and surface the others only as a subtle
"2 of 3" affordance if it costs you little. Two version shapes:

**User** — `{ type: "singleStep", role: "user", content: [...] }` where each content part is:

```jsonc
{ "type": "text", "text": "Describe" }
{ "type": "file", "fileIdentifier": "1784921393420 - 431.png",
  "fileType": "image", "sizeBytes": 100050 }
```

**Assistant** — `{ type: "multiStep", role: "assistant", senderInfo: { senderName: "<model id>" },
steps: [...] }`. Step types observed:

- `contentBlock` (35) — has `content: [{ type: "text", text: … }]`. **If `style.type == "thinking"`
  (13 of them), this is reasoning** — render it collapsed by default, visually distinct, expandable.
- `debugInfoBlock` (22) — timings/metadata. Collapse it away or hide it behind a disclosure; it is
  not conversation.

Also present: `empty.conversation.json` with **zero messages** — handle it without an empty-state bug.

### Images: `~/.lmstudio/user-files/`

A `file` content part's `fileIdentifier` **is the filename**: `user-files/<fileIdentifier>` is the
real PNG. Alongside it sits `<fileIdentifier>.metadata.json`:

```jsonc
{ "type": "image", "sizeBytes": 100050, "originalName": "image.png",
  "fileIdentifier": "1784921393420 - 431.png",
  "preview": { "data": "data:image/png;base64,iVBORw0KGgo…" } }
```

The sidecar's `preview.data` is a ready-to-render base64 data URI — **use it for thumbnails**, and
load the full file only when the user opens the image larger. There are 3 images / 2.6 MB today, but
handle **multiple images in one message** and a **missing** referenced file (render a placeholder,
never crash).

---

## Architecture — follow the existing feature, don't invent a parallel one

This feature is a sibling of one that just shipped. **Read all of these before writing code:**

- `src/Services/AIStorageCollector.swift` — an `actor`. Note `init(settings:root:)` with the
  **injectable root** (defaults to the real home; tests point it at a temp dir), the
  `AIStoragePathGuard.isReadable(path:homePath:)` root guard, and the read-only
  `listFiles` / `readTail` / `readFull` / `readWindow`.
- `src/Services/AIStorageModel.swift` — the `@MainActor` `ObservableObject` with thin async wrappers
  returning `AIStorageFileContent` (`access: .ok/.denied/.missingFile`).
- `src/Views/AIStorageLogsSheet.swift` — the log browser. **This is your design reference**: two-column
  sheet, month-sectioned `LazyVStack` list, SF Mono viewer, designed empty/binary/denied/missing
  placeholders, keyboard cursor with arrows/Return, `@ScaledMetric` a11y, scheme-aware colors.
- `src/Views/AIStoragePanelView.swift` — the panel and its `actions` row (*Search retained text…*,
  *Explore logs…*, *Purge…*).
- `src/Models/SystemMetrics.swift` — `AIStorageTarget`, `AIStorageSnapshot`, `AIStorageFileEntry`,
  and the `#if DEBUG` preview fixtures.

**Build a new `src/Views/AIStorageChatsSheet.swift` rather than adding a mode to the logs sheet.**
The logs sheet is already ~1200 lines and its byte-window paging machinery is irrelevant to chats.
Give it its own **Explore chats…** button in `AIStoragePanelView.actions`, enabled only when the
`lmstudio.conversations` target exists.

### Hard constraints

- **Strictly read-only.** No delete/rename/move/write control, and no filesystem write. Every path
  you read must pass the existing `AIStoragePathGuard.isReadable` root guard, resolving symlinks
  first exactly the way `AIStorageCollector.resolvedIfReadable` does.
- **Do not disturb** `AIStorageSearchSheet`, `AIStoragePurgeSheet`, or the logs sheet. In particular
  the purge sheet's "destructive control must not move under the pointer" invariant is untouchable.
- Opening the viewer must **not** trigger `AIStorageModel.rescan()` / `scanIfStale()` or disturb the
  2 s `MetricsManager` tick — do your own fast, cancellable read, like `listFiles` does.
- Keep collector work on the actor and off the main thread; keep the model wrappers thin.
- Never load a whole conversation's images into memory eagerly — thumbnails come from the sidecar
  preview.

---

## What to build

1. **Parsing layer — pure and testable.** Decode the conversation JSON into view models
   (`ChatTranscript`, `ChatTurn`, `ChatPart`, reasoning vs answer vs debug). Put the decoding in
   **pure, filesystem-free functions/types** so they can be unit-tested from a JSON literal, mirroring
   how `AIStorageLogLayout` / `AIStorageTailReader` are tested. Be **defensive**: unknown `type`
   values, missing keys, an out-of-range `currentlySelected`, and zero messages must all degrade
   gracefully rather than throw away the conversation.
2. **Collector + model APIs.** Root-guarded, read-only, cancellable: list conversations (newest first,
   with title, model, message count, date), load one transcript, and load an image
   (thumbnail via sidecar preview; full file on demand). Add them alongside the existing read APIs and
   expose thin `@MainActor` wrappers.
3. **The sheet.** Two-column, sized like the logs sheet (~820 pt): left, the conversation list
   (title — falling back to a formatted date when `name` is null — plus model, turn count, relative
   date, pinned marker); right, the rendered transcript. Turns visually distinguished by role,
   selectable text, images inline at a sensible max size with click-to-enlarge, reasoning blocks
   collapsed by default and clearly marked as reasoning, `debugInfoBlock` tucked away, and the
   system prompt available but not shouting. Designed states for: loading, no conversations, empty
   conversation, missing image, unreadable file.
4. **Polish to the level of the logs sheet.** Keyboard navigation (arrows move selection, Return
   opens), VoiceOver labels on rows and turns, Dynamic Type on non-mono text, correct light **and**
   dark appearance, and a `#Preview` driven by a fixture so the populated and empty states render
   without a home directory.

---

## Design bar

Front-end design quality is the point here, not an afterthought. Reference **Console.app / Finder**
for the list, and real chat UIs for the transcript — but stay a sibling of `AIStorageLogsSheet`:
same material and border language, same 13/12/11/10 pt typographic steps, SF Mono only where text is
genuinely code/log-like. It should look hand-designed and native. Reject the bland default, and
reject anything that reads as generic AI chat chrome.

---

## Testing

Per the repo owner: **unit tests yes, screenshot capture and scripted hands-on walkthroughs no.**

- Add `XCTest` cases for the **pure parsing layer** — a realistic conversation literal (user text +
  image part, assistant with a thinking step, a `debugInfoBlock`, a multi-version message), the
  zero-message file, and the malformed/unknown-type degradation paths. Follow the existing idiom
  (`@testable import`, pure static helpers) — read `Tests/MacResourceMonitorTests/AIStorageTailReaderTests.swift`
  first.
- If you add a filesystem-level test, plant your fixture root under the package's `.build/`
  directory, **not** `/tmp` or `/var/folders`: those sit behind macOS's `/private` symlinks, and
  `URL.resolvingSymlinksInPath()` then disagrees with the directory enumerator's raw paths, which
  makes the root guard fail spuriously. This already bit us once.
- **Do not** build an `ImageRenderer` screenshot harness or write PNGs to `docs/`.
- `swift build` clean and the **full** suite green (84 baseline + yours) before you finish.

The repo owner does visual sign-off by hand, so nothing downstream will catch a layout mistake for
you. Get the states right the first time.

---

## When you're done

1. **Commit to `main`.** `git add` only files you touched. Repo conventions: **never mention Claude,
   Anthropic, AI, or any AI attribution in the commit message**; never commit
   `.claude/settings.local.json`. **Do not push** — pushing needs the owner's say-so.
2. **Report back** with: what you built, the commit SHA, files added/modified, final `swift test`
   counts, anything you deferred and why, and — most importantly — **what the owner should look at
   during manual visual sign-off**, since no screenshots were taken.

Complete the whole feature. If some part turns out to be a bad idea, still attempt it and say so in
your report rather than silently dropping it.

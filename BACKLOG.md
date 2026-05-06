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

## Ollama support

Detect and surface Ollama alongside (or instead of) LM Studio. Ollama's local API runs at `http://localhost:11434` — `GET /api/ps` returns currently-loaded models with size/VRAM info.

- Auto-detect which provider is running (LM Studio on :1234, Ollama on :11434, or both)
- Show loaded model name + memory footprint in the dashboard card
- Degrade silently when neither is running

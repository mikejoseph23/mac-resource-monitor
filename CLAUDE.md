# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                    # Debug build
swift build -c release         # Release build
swift run MacResourceMonitor   # Run the app
```

No external dependencies — all metrics collected via macOS system APIs (Mach, sysctl, IOKit).

Requires macOS 14.0+ (Sonoma). Swift 5.9+. SPM-based (Package.swift).

There is no test suite yet.

## Architecture

Native SwiftUI macOS app (bundle ID: `com.mikejoseph.mac-resource-monitor`) that consolidates system resource monitoring into a single dashboard. Built for a Mac Studio M3 Ultra. Runs as both a windowed app and a menu bar extra.

### Data Flow

`MetricsManager` (observable singleton) runs a 2-second timer that calls all collectors, aggregates results into a `SystemSnapshot`, and publishes via `@Published` for SwiftUI consumption.

### Layers

- **Models** (`src/Models/`) — Immutable metric structs (`CPUMetrics`, `MemoryMetrics`, etc.) and `MetricsHistory` (in-memory ring buffer, 300 snapshots max).
- **Services** (`src/Services/`) — One collector per metric type (`CPUCollector`, `MemoryCollector`, `GPUCollector`, `DiskCollector`, `NetworkCollector`, `ProcessCollector`, `ThermalCollector`, `SelfMetricsCollector`). Each tracks deltas across samples for rate calculations. `MetricsManager` orchestrates them all.
- **Views** (`src/Views/`) — `DashboardView` (tabbed: metric cards grid + process list), `MetricCardView` (reusable card with sparkline and severity indicator), `ProcessListView` (sortable table with grouped processes), `MenuBarView` (compact popover), `SelfMetricsView` (app's own resource usage in footer).

## Project Layout

- `src/` — App source code (SwiftUI, models, services, views)
- `marketing/` — App Store content and promotional materials
- `docs/` — Project documentation

### System API Usage

- **CPU**: Mach `host_processor_info` for per-core ticks, delta-based percentage calculation
- **Memory**: `host_statistics64` for active/wired/compressed/cached/swapped breakdown
- **GPU**: IOKit IOAccelerator registry for Apple Silicon GPU utilization
- **Disk I/O**: IORegistry cumulative byte/op counts, converted to rates per interval
- **Network**: `NET_RT_IFLIST2` sysctl for 64-bit counters (avoids 32-bit overflow)
- **Processes**: Tries detailed process info first, falls back to sysctl for restricted processes
- **Thermal**: `ProcessInfo.thermalState`

### Key Design Decisions

- No sandboxing (entitlements file) — required for unrestricted system API access
- App stays running when window is closed (`applicationShouldTerminateAfterLastWindowClosed` returns false) since menu bar extra persists
- Process grouping rolls helper processes under parent app name via path matching (e.g., Chrome Helper → Chrome)
- GPU core count defaults to 80 for M3 Ultra — hardcoded in `GPUCollector`

## Conventions

- Don't mention claude or anthropic in git commits
- Escape dollar signs in markdown with backslash (`\$`)
- Add blank lines before and after markdown lists
- Never commit `.claude/settings.local.json`

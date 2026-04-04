# Mac Resource Monitor — Planning Document

## Overview

A native macOS app that consolidates system resource monitoring into a single dashboard view, eliminating the need to tab-switch in Activity Monitor. Built primarily for a Mac Studio M3 Ultra (512GB unified memory, 80-core GPU) with a focus on local AI inference workloads.

## Pain Point

Activity Monitor requires switching between multiple tabs (CPU, Memory, Disk, Network, GPU) to get a full picture of system resource usage. There's no consolidated view, and no awareness of AI inference workloads (LM Studio, Ollama, etc.).

## Core Features (MVP)

### 1. Consolidated Dashboard

- **Fixed layout** — single window showing all key metrics at a glance
- **Metrics displayed:**
  - CPU utilization (aggregate, with drill-down to per-core)
  - Memory / unified memory pressure (aggregate, with drill-down)
  - Disk I/O (read/write rates)
  - Network throughput (in/out)
  - GPU utilization (aggregate, with drill-down to per-core)
  - Thermal state / throttling detection
  - SSD read/write rates
- **Live values** + trailing **history graphs** (sparklines/charts) per metric
- **In-memory history** only (no persistence to disk for MVP)

### 2. Per-App Resource Breakdown

- Processes **grouped by application** (e.g., all Chrome helpers rolled up under "Chrome")
- Expandable sub-groups to see individual processes
- Useful for identifying irregular resource hogs

### 3. AI Backend Monitoring

- **Pluggable architecture** — designed to support multiple AI inference backends
- **LM Studio integration** (first backend):
  - Loaded models and VRAM/memory usage per model
  - Inference speed (tokens/sec)
  - Active requests / queue depth
  - Real-time processing activity
  - Connects to default local API endpoint
- **Ollama** as a planned second backend
- Graceful handling when backends aren't running (disabled/not-detected state)

### 4. Menu Bar / Widget Companion

- Compact summary view accessible from menu bar
- Popover with key stats (CPU %, memory %, GPU %, AI backend status)
- Option to open full app window from popover

### 5. Settings

- **Refresh rates:** configurable with sensible defaults per metric type
- **Background behavior:** three modes:
  - Full rate (keep updating normally)
  - Throttled (reduced polling frequency)
  - Paused (no updates until foregrounded)
- **Auto-throttle:** automatically reduce polling when system is under heavy load
- **AI backend endpoints:** configurable (defaults for now)

### 6. Self-Monitoring

- Small indicator showing the app's own CPU/memory footprint
- Keeps the monitor honest about its own resource impact

## UI / UX

- **Appearance:** follow system dark/light mode
- **Layout:** fixed dashboard (not customizable for MVP)
- **Drill-down pattern:** aggregate values on dashboard, click to expand per-core or per-process detail
- **Launch:** manual only (no login item for MVP)
- **Keyboard shortcuts:** none planned for MVP

## Tech Stack

- **To be evaluated during implementation.** Options include:
  - **Swift / SwiftUI** — native, modern, fast to build
  - **Swift / AppKit** — more control for custom graph rendering
  - **Tauri (Rust + web UI)** — cross-platform potential, good charting libraries
  - Other options as warranted
- Decision should balance: native feel, charting/graph quality, development speed, and future distribution potential

## Target Audience

- Personal use (developer on Mac Studio running local AI workloads)
- Potential future distribution (App Store or GitHub) — avoid sandboxing pitfalls early

## Hardware Context

- **Primary machine:** Mac Studio M3 Ultra
  - 32-core CPU (24P + 8E), 80-core GPU, 32-core Neural Engine
  - 512GB unified memory
  - 4TB SSD (~7.4 GB/s read)
  - 6x Thunderbolt 5, 10Gb Ethernet
  - macOS Sequoia
- Purpose-built for local AI inference (70B+ parameter models in RAM)

## Backlog (Post-MVP)

- [ ] Alerting / notifications (memory pressure critical, thermal throttling, etc.)
- [ ] Persistent history — configurable archiving of metrics to disk
- [ ] Customizable dashboard layout (rearrange/resize panels)
- [ ] Remote machine monitoring (e.g., gaming PC "BEAST" in home lab)
- [ ] Neural Engine metrics (if Apple exposes better APIs)
- [ ] Additional AI backends beyond LM Studio and Ollama
- [ ] Launch at login option
- [ ] Keyboard shortcuts
- [ ] Market research — survey existing tools (iStat Menus, btop, etc.) for inspiration
- [ ] Thunderbolt device / external display monitoring
- [ ] SSD health / wear indicators
- [ ] Export / share snapshots of dashboard state

## Non-Goals (MVP)

- No persistent data storage
- No alerting system
- No remote machine support
- No customizable layout
- No auto-launch at login

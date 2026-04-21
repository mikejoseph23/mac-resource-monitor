# Mac Resource Monitor

A native macOS dashboard that consolidates system resource monitoring into a single window. Built with SwiftUI for Apple Silicon Macs.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

![Mac Resource Monitor dashboard](screenshot.png)

## Why

Activity Monitor scatters the picture across five tabs — CPU here, Memory there, Disk and Network somewhere else. Seeing *everything at once* means constant tab-switching, and sparklines reset the moment you look away.

Mac Resource Monitor consolidates it all into one always-on dashboard: CPU, memory, GPU, disk, network, thermals, and top processes on a single screen with rolling history so you can actually see trends.

It was also built with **LM Studio** (and local LLM workloads generally) in mind. When you're running a 70B model on Apple Silicon, you want to see GPU utilization, unified memory pressure, and thermal state side-by-side in real time — not tab through panes hoping to catch the spike.

## Features

- **CPU** — Per-core utilization with efficiency/performance core breakdown
- **Memory** — Active, wired, compressed, cached, and swap usage
- **GPU** — Apple Silicon GPU utilization via IOKit
- **Disk I/O** — Read/write rates and volume capacity
- **Network** — Per-interface throughput (64-bit counters)
- **Processes** — Sortable process list with grouped helper processes and delta CPU tracking
- **Thermal** — System thermal state
- **LM Studio** — Optional integration for local LLM monitoring
- **Menu Bar Extra** — Compact popover with key metrics, stays running when the window is closed

No external dependencies. All metrics collected via macOS system APIs (Mach, sysctl, IOKit).

## Requirements

- macOS 14.0+ (Sonoma)
- Swift 5.9+
- Apple Silicon Mac (GPU metrics are tailored for Apple Silicon; CPU defaults tuned for M3 Ultra)

## Build & Run

```bash
swift build                    # Debug build
swift build -c release         # Release build
swift run MacResourceMonitor   # Run the app
```

## Project Structure

```
src/
  Models/         # Immutable metric structs and in-memory history ring buffer
  Services/       # One collector per metric type, orchestrated by MetricsManager
  Views/          # SwiftUI views — dashboard, metric cards, sparklines, process list
  Extensions/     # Swift extensions
  Resources/      # App icon
```

## How It Works

`MetricsManager` runs a 2-second timer that calls all collectors, aggregates results into a `SystemSnapshot`, and publishes via `@Published` for SwiftUI consumption. History is kept in a 300-snapshot ring buffer (~10 minutes).

## Configuration

- **GPU core count** is hardcoded to 80 in `GPUCollector.swift` for the M3 Ultra. Adjust this for your hardware.
- **No sandboxing** — the app requires unrestricted access to system APIs for full metric collection.

## License

MIT -- Copyright (c) 2026 [Interapp Development, Inc.](https://interappdev.com)

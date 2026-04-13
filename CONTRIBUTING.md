# Contributing

Thanks for your interest in Mac Resource Monitor! Here's how to get involved.

## Getting Started

1. Fork the repo
2. Clone your fork and build:

   ```bash
   git clone https://github.com/YOUR_USERNAME/mac-resource-monitor.git
   cd mac-resource-monitor
   swift build
   swift run MacResourceMonitor
   ```

3. Create a branch for your change:

   ```bash
   git checkout -b my-feature
   ```

## Development

- **No external dependencies** — keep it that way unless there's a strong reason not to.
- **macOS 14+, Swift 5.9+** — don't lower the deployment target.
- Source lives in `src/` with subdirectories for Models, Services, Views, Extensions, and Resources.
- `Package.swift` must stay at the repo root (SPM requirement).

## Making Changes

- Keep commits focused — one logical change per commit.
- Test your changes on real hardware. There's no test suite yet, so manual verification matters.
- If you're adding a new collector, follow the existing pattern: one file in `Services/`, corresponding metric struct in `Models/SystemMetrics.swift`, wired up in `MetricsManager`.
- GPU core count and other hardware-specific values should be configurable, not hardcoded to your machine.

## Submitting a Pull Request

1. Push your branch to your fork
2. Open a PR against `main`
3. Describe what you changed and why
4. Include screenshots for UI changes

## Reporting Issues

Open an issue with:

- macOS version and Mac model
- Steps to reproduce
- Expected vs. actual behavior
- Console output if relevant (`swift run MacResourceMonitor` from terminal)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

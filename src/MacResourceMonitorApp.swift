import SwiftUI

@main
struct MacResourceMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var metricsManager = MetricsManager()
    @StateObject private var layout = DashboardLayout()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(metricsManager)
                .environmentObject(layout)
        }
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mac Resource Monitor") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        NSApplication.AboutPanelOptionKey.applicationName: "Mac Resource Monitor",
                        NSApplication.AboutPanelOptionKey.applicationVersion: version,
                    ])
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(metricsManager)
                .environmentObject(layout)
        } label: {
            MenuBarLabel()
                .environmentObject(metricsManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(layout)
        }
    }
}

/// Live menu-bar label (#12). Replaces the former static gauge glyph: reads
/// `MetricsManager`'s published snapshot so it re-renders on each 2s collection
/// tick — no second timer or collection path. Kept deliberately lightweight
/// (a couple of formatted strings) since the menu-bar label re-renders often.
///
/// Rendered as a *single* concatenated `Text` (both segments in one label)
/// rather than a multi-child `HStack`. `MenuBarExtra` (`.window` style) sizes
/// its `NSStatusItem` from the first render and does not grow the item when a
/// later, wider layout arrives — with an `HStack` the second (GPU) segment gets
/// clipped off the right edge (#12). A single `Text` is measured and sized
/// reliably, so both segments always show.
///
/// The segments are labeled with the text prefixes `CPU`/`GPU` rather than SF
/// Symbols: symbol glyphs embedded in a `Text` (via `Text(Image:)` *or*
/// `"\(Image)"` interpolation) do **not** paint inside this menu-bar label — they
/// occupy zero width and render invisibly — even though `Image` views paint fine
/// in an `HStack` (but that layout clips, per above). Verified on-screen; see the
/// worker summary. Text labels are also clearer than icons at menu-bar size.
///
/// The pre-snapshot state uses `--%` placeholders so the width never changes when
/// the first snapshot lands. `.monospacedDigit()` keeps the width steady as values
/// change.
///
/// Note: the per-run `.foregroundColor` (severity coloring) is retained for intent
/// and forward-compatibility, but does **not** visibly paint here — macOS renders
/// a `MenuBarExtra` label as a monochrome template image, stripping foreground
/// color. This was already true of the pre-fix code; it is a platform limitation,
/// not a regression. Verified on-screen at 100% CPU (digits render white, not red).
private struct MenuBarLabel: View {
    @EnvironmentObject private var metricsManager: MetricsManager

    var body: some View {
        let snapshot = metricsManager.currentSnapshot
        (
            Text("CPU ") + segment(snapshot?.cpu.totalUsage)
            + Text("   GPU ") + segment(snapshot?.gpu.utilizationPercent)
        )
        .font(.system(size: 11, weight: .medium).monospacedDigit())
    }

    /// One metric readout as a colored `Text` run: severity-colored percentage
    /// once data lands, a neutral `--%` placeholder before the first snapshot.
    private func segment(_ value: Double?) -> Text {
        if let value {
            return Text(percent(value))
                .foregroundColor(MetricSeverity.utilization(value).color)
        } else {
            return Text("--%")
                .foregroundColor(.secondary)
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app appears in the Dock and has a proper menu bar
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Set dock icon from the .app bundle's Resources (Info.plist CFBundleIconFile also handles this).
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

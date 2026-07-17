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
private struct MenuBarLabel: View {
    @EnvironmentObject private var metricsManager: MetricsManager

    var body: some View {
        if let snapshot = metricsManager.currentSnapshot {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(percent(snapshot.cpu.totalUsage))
                    .foregroundStyle(MetricSeverity.utilization(snapshot.cpu.totalUsage).color)
                Image(systemName: "rectangle.3.group")
                Text(percent(snapshot.gpu.utilizationPercent))
                    .foregroundStyle(MetricSeverity.utilization(snapshot.gpu.utilizationPercent).color)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
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

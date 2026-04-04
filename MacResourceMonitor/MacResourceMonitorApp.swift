import SwiftUI

@main
struct MacResourceMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var metricsManager = MetricsManager()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(metricsManager)
        }
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mac Resource Monitor") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        NSApplication.AboutPanelOptionKey.applicationName: "Mac Resource Monitor",
                        NSApplication.AboutPanelOptionKey.applicationVersion: "0.1.0",
                    ])
                }
            }
        }

        MenuBarExtra("Resource Monitor", systemImage: "gauge.with.dots.needle.33percent") {
            MenuBarView()
                .environmentObject(metricsManager)
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app appears in the Dock and has a proper menu bar
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

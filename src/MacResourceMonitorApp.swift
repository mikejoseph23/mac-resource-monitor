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

        MenuBarExtra("Resource Monitor", systemImage: "gauge.with.dots.needle.33percent") {
            MenuBarView()
                .environmentObject(metricsManager)
                .environmentObject(layout)
        }
        .menuBarExtraStyle(.window)
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

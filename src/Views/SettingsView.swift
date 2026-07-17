import SwiftUI
import ServiceManagement

/// Standard app Settings scene (⌘,). Replaces the old slider-icon popover
/// that lived in the dashboard toolbar: it hosts the per-widget show/hide
/// toggles that used to be behind that popover, plus launch-at-login and the
/// GPU core-count override (#13).
struct SettingsView: View {
    @EnvironmentObject private var layout: DashboardLayout

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            WidgetSettingsView()
                .environmentObject(layout)
                .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
        }
        .frame(width: 460)
        .padding(.vertical, 4)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @StateObject private var loginItem = LoginItemModel()

    /// 0 means "no override" — the collector falls back to the detected / tier
    /// core count. Shared key with `GPUCollector.coreCountOverrideKey`.
    @AppStorage(GPUCollector.coreCountOverrideKey) private var gpuCoreOverride: Int = 0

    private var overrideEnabled: Binding<Bool> {
        Binding(
            get: { gpuCoreOverride > 0 },
            set: { gpuCoreOverride = $0 ? max(gpuCoreOverride, 1) : 0 }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if let message = loginItem.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Override GPU core count", isOn: overrideEnabled)
                    .help("Force the GPU core count used by the GPU card when auto-detection is wrong for your chip.")
                if overrideEnabled.wrappedValue {
                    Stepper(value: $gpuCoreOverride, in: 1...256) {
                        HStack {
                            Text("Cores")
                            Spacer()
                            Text("\(gpuCoreOverride)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Applies on the next collection tick.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Using auto-detected core count.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("GPU")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Widgets

private struct WidgetSettingsView: View {
    @EnvironmentObject private var layout: DashboardLayout

    var body: some View {
        let supportsAS = Architecture.isAppleSilicon
        let widgets = DashboardWidget.allCases.filter { !$0.requiresAppleSilicon || supportsAS }
        return Form {
            Section {
                ForEach(widgets) { widget in
                    Toggle(widget.displayName, isOn: Binding(
                        get: { layout.isVisible(widget) },
                        set: { layout.setVisible(widget, $0) }
                    ))
                }
            } header: {
                Text("Show or hide dashboard widgets")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Login item

/// Wraps `SMAppService.mainApp` for the launch-at-login toggle. Reads the
/// current registration state on init and reflects register/unregister
/// results (including the common "requires a real .app bundle" failure when
/// run via `swift run`) back into `statusMessage`.
@MainActor
private final class LoginItemModel: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var statusMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            statusMessage = nil
        } catch {
            statusMessage = "Couldn't update login item: \(error.localizedDescription)"
        }
        refresh()
    }
}

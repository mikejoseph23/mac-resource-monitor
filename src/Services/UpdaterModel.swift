import Foundation
import Sparkle

/// Thin SwiftUI-facing wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Sparkle drives the whole update flow itself (appcast fetch, EdDSA signature
/// verification, download, install-on-quit) off the keys in `Info.plist`
/// (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
/// `SUScheduledCheckInterval`) — this type just owns the controller and exposes
/// the two things the UI needs: a `checkForUpdates()` action for the
/// "Check for Updates…" menu item, and a bindable
/// `automaticallyChecksForUpdates` toggle for Settings. `canCheckForUpdates`
/// mirrors Sparkle's own published property so the menu item disables itself
/// while a check is already in flight.
///
/// `startingUpdater: true` starts the updater immediately, which also kicks off
/// the scheduled background checks when `SUEnableAutomaticChecks` is on.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Show Sparkle's standard "Check for Updates" UI (manual check).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Bindable mirror of Sparkle's automatic-check preference. Sparkle persists
    /// this in its own `UserDefaults` (`SUEnableAutomaticChecks`), so the
    /// Settings toggle stays in sync across launches without extra storage.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

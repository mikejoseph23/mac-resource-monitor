import SwiftUI

/// Deletion lives in a modal sheet, never inline in the panel: the dashboard
/// repaints every 2 seconds, and a destructive control must not move or
/// re-render under the pointer between the decision and the click.
struct AIStoragePurgeSheet: View {
    @ObservedObject var model: AIStorageModel
    @Environment(\.dismiss) private var dismiss

    /// Nothing is pre-checked. Every byte deleted here is deliberately chosen.
    @State private var selected: Set<String> = []
    @State private var phase: Phase = .selecting
    @State private var typedConfirmation = ""
    @State private var omlxRunning: Bool?
    @State private var stoppingServer = false
    @State private var serverStopFailed = false
    @State private var result: AIStoragePurgeResult?

    private enum Phase {
        case selecting, confirming, purging, done
    }

    /// Above this, a checkbox and a button aren't enough — the user types the
    /// word.
    private let typedConfirmationThreshold: UInt64 = 1_073_741_824

    private var targets: [AIStorageTarget] {
        (model.snapshot?.targets ?? []).filter { $0.exists && $0.sizeBytes > 0 }
    }

    private var selectedTargets: [AIStorageTarget] {
        targets.filter { selected.contains($0.id) }
    }

    private var selectedBytes: UInt64 {
        selectedTargets.reduce(0) { $0 + $1.sizeBytes }
    }

    private var selectionNeedsOMLXStopped: Bool {
        selectedTargets.contains { $0.requiresOMLXStopped }
    }

    private var blockedByRunningServer: Bool {
        selectionNeedsOMLXStopped && omlxRunning == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            switch phase {
            case .selecting, .confirming, .purging:
                selectionBody
            case .done:
                resultBody
            }

            Divider()
            footer
        }
        .frame(width: 560)
        .task {
            omlxRunning = await model.isOMLXRunning()
        }
    }

    // MARK: - Header / footer

    private var headerBar: some View {
        HStack {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("Purge Local AI Storage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if phase == .purging {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Deleting…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !selected.isEmpty && phase != .done {
                Text("\(aiStorageFormatBytes(selectedBytes)) selected")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if phase == .done {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .purging)

                Button(role: .destructive) {
                    if phase == .confirming || !needsTypedConfirmation {
                        purge()
                    } else {
                        phase = .confirming
                    }
                } label: {
                    Text(deleteButtonTitle)
                }
                .keyboardShortcut(.return)
                .disabled(!canDelete)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var needsTypedConfirmation: Bool {
        selectedBytes >= typedConfirmationThreshold
    }

    private var deleteButtonTitle: String {
        if phase == .confirming { return "Delete Permanently" }
        return needsTypedConfirmation ? "Continue…" : "Delete"
    }

    private var canDelete: Bool {
        guard phase != .purging, !selected.isEmpty, !blockedByRunningServer else { return false }
        if phase == .confirming {
            return typedConfirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE"
        }
        return true
    }

    // MARK: - Selection

    private var selectionBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                warningBox

                ForEach(model.snapshot?.presentProviders ?? []) { provider in
                    let rows = targets.filter { $0.provider == provider }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(provider.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(rows) { target in
                                row(target)
                            }
                        }
                    }
                }

                if selectionNeedsOMLXStopped {
                    serverBox
                }

                if phase == .confirming {
                    typedConfirmationBox
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 420)
    }

    /// Stated plainly and not softened. This is `unlink(2)` on an APFS SSD.
    private var warningBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text("This is an ordinary delete on an APFS SSD, not a secure erase. The blocks are unlinked, not overwritten, and forensic recovery is possible. For genuinely sensitive material the only real answers are an encrypted volume, or not letting it be written in the first place.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private func row(_ target: AIStorageTarget) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(target.id) },
            set: { on in
                if on { selected.insert(target.id) } else { selected.remove(target.id) }
                if phase == .confirming { phase = .selecting; typedConfirmation = "" }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(target.label)
                        .font(.system(size: 12, weight: .medium))
                    Text(aiStorageFormatBytes(target.sizeBytes))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(target.displayPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(target.contents)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(phase == .purging)
    }

    /// oMLX holds the KV cache open; deleting it under a live server corrupts
    /// its view of the cache. We never kill the process — the user either stops
    /// it here through `omlx stop`, or the selection stays blocked.
    private var serverBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: omlxRunning == true ? "exclamationmark.octagon.fill" : "checkmark.circle")
                .foregroundStyle(omlxRunning == true ? Color.red : Color.secondary)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 6) {
                if omlxRunning == nil {
                    Text("Checking whether the oMLX server is running…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if omlxRunning == true {
                    Text("The oMLX server is running. Its prompt cache can't be purged while it holds the files open.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Run “omlx stop”") { stopServer() }
                            .controlSize(.small)
                            .disabled(stoppingServer)
                        if stoppingServer {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                        Button("Re-check") {
                            Task { omlxRunning = await model.isOMLXRunning() }
                        }
                        .controlSize(.small)
                        .disabled(stoppingServer)
                    }
                    if serverStopFailed {
                        Text("Couldn't stop the server — stop it yourself, then re-check.")
                            .font(.system(size: 10)).foregroundStyle(.red)
                    }
                    Text("You'll need to run “omlx start” afterwards; nothing here restarts it for you.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    Text("The oMLX server isn't running, so its cache is safe to purge. Start it again with “omlx start” when you're done.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((omlxRunning == true ? Color.red : Color.primary).opacity(0.06)))
    }

    private var typedConfirmationBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You're about to delete \(aiStorageFormatBytes(selectedBytes)). Type DELETE to confirm.")
                .font(.system(size: 11, weight: .medium))
            TextField("DELETE", text: $typedConfirmation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.07)))
    }

    // MARK: - Result

    private var resultBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result {
                HStack(spacing: 8) {
                    Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.failures.isEmpty ? Color.green : Color.orange)
                    Text("Freed \(aiStorageFormatBytes(result.freedBytes))")
                        .font(.system(size: 13, weight: .semibold))
                }
                if !result.removedTargets.isEmpty {
                    Text("Cleared: " + result.removedTargets.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !result.failures.isEmpty {
                    Text("Some files could not be removed in: " + result.failures.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if selectionNeedsOMLXStopped {
                    Text("Run “omlx start” to bring the oMLX server back.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing was deleted.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - Actions

    private func stopServer() {
        stoppingServer = true
        serverStopFailed = false
        Task {
            let stopped = await model.stopOMLXServer()
            stoppingServer = false
            serverStopFailed = !stopped
            omlxRunning = await model.isOMLXRunning()
        }
    }

    private func purge() {
        // Last line of defence: never delete the KV cache with the server up,
        // even if the state above somehow got stale.
        guard !blockedByRunningServer else { return }
        phase = .purging
        let ids = selected
        Task {
            if selectionNeedsOMLXStopped, await model.isOMLXRunning() {
                phase = .selecting
                omlxRunning = true
                return
            }
            result = await model.purge(targetIDs: ids)
            phase = .done
        }
    }
}

#Preview {
    AIStoragePurgeSheet(model: AIStorageModel(previewSnapshot: .preview))
}

import SwiftUI

struct GeneralSettings: View {
    @Bindable var model: ConnectionModel
    @ObservedObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    @State private var removalPending = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Launch GPBar at login", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }
                    ))
                    Text("Launching GPBar does not connect the VPN.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("General") }

                Section {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    ))
                    .disabled(updates.unavailableReason != nil)
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                    Text(updates.unavailableReason ?? "GPBar asks before installing. Disconnect the VPN before updating.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.updating {
                        Text("Finish the update or restart GPBar before connecting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Updates") }

                Section {
                    HStack(alignment: .top) {
                        Image(systemName: model.helperVerified ? "checkmark.circle" : "lock.circle")
                            .foregroundStyle(model.helperVerified ? Color("Connected") : .secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.helperVerified ? "Helper ready" : "VPN helper")
                            Text(model.helperMessage).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.checkingHelper {
                            ProgressView().controlSize(.small)
                        } else if model.helperStatus == .requiresApproval {
                            Button("Open settings") { model.openSystemSettings() }
                        } else if model.helperStatus == .enabled {
                            Button("Check again") { model.refresh() }
                        } else {
                            Button("Set up") { model.registerHelper() }
                        }
                    }
                    .disabled(model.updating)
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(Color("Failure"))
                            .textSelection(.enabled)
                    }
                    if model.cleanupRequired || model.phase == .unknown {
                        Text("GPBar restores only the network changes recorded for its sessions.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(model.recovering ? "Checking network…" : "Recover network") { model.recoverNetwork() }
                            .disabled(model.updating || model.recovering || !model.helperVerified)
                    }
                    Button("Remove helper") {
                        removalPending = true
                        Task { await model.unregisterHelper(); removalPending = false }
                    }
                    .disabled(model.updating || removalPending || model.helperStatus == .notRegistered || model.settingsLocked || model.cleanupRequired)
                } header: { Text("VPN helper") }

                if model.profiles.loginSSOPortal != nil {
                    Section {
                        Text("macOS login SSO is enabled for one portal. Disable it before removing the helper or updating GPBar.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Disable macOS login SSO") { model.configureLoginSSO(enabled: false) }
                            .disabled(model.settingsLocked || model.updating || !model.helperVerified)
                        if let message = model.loginSSOMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: { Text("macOS login SSO") }
                }
                if !model.profiles.retired.isEmpty {
                    Section {
                        Text("Saved sign-in removal is pending for a deleted connection. Unlock Keychain, then try again.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Retry removal") { model.refresh() }
                    } header: { Text("Saved sign-in cleanup") }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Connections…") { openWindow(id: "connection") }
                Spacer()
                #if DEBUG
                Button("Diagnostics…") { openWindow(id: "diagnostics") }
                #endif
                Button("About GPBar…") { openWindow(id: "about") }
            }
            .font(.caption)
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(minWidth: 480, minHeight: 580)
        .onAppear { model.refresh() }
    }
}

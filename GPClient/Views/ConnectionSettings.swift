import SwiftUI

struct ConnectionSettings: View {
    @Bindable var model: ConnectionModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var addressFocused: Bool

    var body: some View {
        @Bindable var preferences = model.preferences
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "network")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your connection")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("One address. Your chosen sign-in browser.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Connection address", text: $preferences.addressDraft, prompt: Text("vpn.example.com"))
                            .textContentType(.URL)
                            .focused($addressFocused)
                            .onSubmit { preferences.saveAddress() }
                        if let error = preferences.addressError {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(Color("Failure"))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !preferences.portal.isEmpty && preferences.addressDraft == preferences.portal {
                            Label("Saved on this Mac", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Use your organization’s GlobalProtect portal. Valid addresses save automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    TextField("Display name", text: $preferences.displayName, prompt: Text("Optional"))
                } header: { Text("Connection") }
                .disabled(model.settingsLocked)

                Section {
                    Picker("Sign in using", selection: $preferences.browser) {
                        ForEach(BrowserChoice.allCases) { browser in Text(browser.title).tag(browser) }
                    }
                    if preferences.browser == .specific {
                        Picker("Browser application", selection: $preferences.browserID) {
                            Text("Select a browser").tag("")
                            ForEach(model.installedBrowsers, id: \.path) { url in
                                if let id = Bundle(url: url)?.bundleIdentifier {
                                    Text(url.deletingPathExtension().lastPathComponent).tag(id)
                                }
                            }
                        }
                    }
                    Text(preferences.browser == .inApp
                         ? "Sign in within GPClient. Some organizations require an external browser."
                         : "Callback capture and automatic tab closure depend on your browser.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: { Text("Browser login") }
                .disabled(model.settingsLocked)

                Section {
                    Toggle("Reconnect an interrupted session", isOn: $preferences.reconnect)
                        .disabled(model.settingsLocked)
                    Toggle("Launch GPClient at login", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }
                    ))
                    Text("Launching GPClient does not connect the VPN.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("On this Mac") }

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
                    if let error = model.error {
                        Text(error).font(.caption).foregroundStyle(Color("Failure"))
                            .textSelection(.enabled)
                    }
                } header: { Text("Permission") }
            }
            .formStyle(.grouped)
            HStack {
                Text("GPClient · Development build").foregroundStyle(.secondary)
                Spacer()
                Button("Diagnostics…") { openWindow(id: "diagnostics") }
                    .buttonStyle(.plain)
                if model.settingsLocked {
                    Button("Disconnect") { model.disconnect() }
                        .disabled(model.phase == .disconnecting)
                } else {
                    Button("Connect") { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.helperVerified || !model.engineAvailable || model.cleanupRequired || PortalAddress.normalize(preferences.addressDraft) == nil)
                }
            }
            .font(.caption)
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .frame(minHeight: 620)
        .onChange(of: addressFocused) { wasFocused, focused in
            if wasFocused && !focused && !preferences.addressDraft.isEmpty { preferences.saveAddress() }
        }
        .onDisappear {
            if !preferences.addressDraft.isEmpty { preferences.saveAddress() }
        }
        .onAppear { model.refresh() }
    }
}

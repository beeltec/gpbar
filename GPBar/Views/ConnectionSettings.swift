import SwiftUI

struct ConnectionSettings: View {
    @Bindable var model: ConnectionModel
    @ObservedObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    @FocusState private var addressFocused: Bool
    @State private var choosingCertificate = false
    @State private var removalPending = false

    var body: some View {
        @Bindable var preferences = model.preferences
        VStack(spacing: 0) {
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
                    Picker("Authentication method", selection: $preferences.authenticationMethod) {
                        ForEach(AuthenticationMethod.allCases) { method in Text(method.title).tag(method) }
                    }
                    switch preferences.authenticationMethod {
                    case .automatic:
                        Text("Detect the portal’s sign-in method when you connect. Browser login uses your saved choice.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .cloudIdentity:
                        Text("Use your organization’s Cloud Identity Engine, including OIDC sign-in. Provider compatibility still needs live validation.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .saml, .password:
                        Text("The portal must support this method. Gateway sign-in follows the gateway’s requirements.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .certificate:
                        Text("Choose a Keychain or smart-card identity. The server can also require a password or SAML sign-in.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Authentication") }
                .disabled(model.settingsLocked)

                if [.automatic, .saml, .cloudIdentity].contains(preferences.authenticationMethod) {
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
                             ? "Sign in within GPBar. Some organizations require an external browser."
                             : "Callback capture and automatic tab closure depend on your browser.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } header: { Text("Browser login") }
                    .disabled(model.settingsLocked)
                }

                if preferences.authenticationMethod == .certificate {
                    Section {
                        HStack(alignment: .top) {
                            Image(systemName: "person.text.rectangle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(preferences.certificateReference == nil ? "No client certificate" : preferences.certificateName)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Choose a certificate only if your organization requires one. Private keys are not exported.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Choose…") {
                                guard preferences.saveAddress() else { return }
                                model.loadCertificates()
                                choosingCertificate = true
                            }
                        }
                        if preferences.certificateReference != nil {
                            if preferences.certificateTokenID != nil {
                                Label(model.selectedTokenMissing ? "Insert the selected token" : "Token available", systemImage: "smartcard")
                                    .font(.caption)
                                Text("macOS asks for your PIN when needed. Removing the token stops this connection.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Toggle("Certificate-only login", isOn: $preferences.certificateOnly)
                            if preferences.certificateOnly {
                                TextField("Certificate username", text: $preferences.certificateUsername, prompt: Text("Optional"))
                                Text("Use the username supplied by your administrator if the certificate does not provide one. Server-required browser sign-in still applies.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button("Remove certificate selection") { model.selectCertificate(nil) }
                        }
                    } header: { Text("Client certificate") }
                    .disabled(model.settingsLocked)
                }

                Section {
                    Toggle("Remember sign-in when allowed", isOn: Binding(
                        get: { preferences.rememberAuthentication }, set: { model.setRememberAuthentication($0) }
                    ))
                    Text("Your VPN controls cookie use and lifetime. GPBar stores allowed cookies in Keychain, never passwords.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Forget saved sign-in") { model.forgetSavedAuthentication() }
                    if let message = model.authenticationStorageMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("Saved sign-in") }
                .disabled(model.settingsLocked)

                Section {
                    Toggle("Reconnect an interrupted session", isOn: $preferences.reconnect)
                        .disabled(model.settingsLocked)
                    Toggle("Launch GPBar at login", isOn: Binding(
                        get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }
                    ))
                    Text("Launching GPBar does not connect the VPN.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("On this Mac") }

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
                } header: { Text("Permission") }
            }
            .formStyle(.grouped)
            HStack {
                #if DEBUG
                Text("GPBar · Development build").foregroundStyle(.secondary)
                #else
                Text("GPBar · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(.secondary)
                #endif
                Spacer()
                #if DEBUG
                Button("Diagnostics…") { openWindow(id: "diagnostics") }
                    .buttonStyle(.plain)
                #endif
                if model.settingsLocked {
                    Button("Disconnect") { model.disconnect() }
                        .disabled(model.phase == .disconnecting)
                } else {
                    Button("Connect") { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.updating || !model.helperVerified || !model.engineAvailable || model.cleanupRequired || PortalAddress.normalize(preferences.addressDraft) == nil)
                }
            }
            .font(.caption)
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .frame(minHeight: 620)
        .sheet(isPresented: $choosingCertificate) {
            CertificatePicker(model: model)
        }
        .onChange(of: addressFocused) { wasFocused, focused in
            if wasFocused && !focused && !preferences.addressDraft.isEmpty { preferences.saveAddress() }
        }
        .onDisappear {
            if !preferences.addressDraft.isEmpty { preferences.saveAddress() }
        }
        .onAppear { model.refresh() }
    }
}

private struct CertificatePicker: View {
    let model: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a client certificate")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Select the identity supplied by your organization. Compare the SHA-256 fingerprint when names match.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.loadingCertificates {
                ProgressView("Reading Keychain…").frame(maxWidth: .infinity, minHeight: 180)
            } else if let error = model.certificateError {
                Text(error).foregroundStyle(Color("Failure")).frame(maxWidth: .infinity, minHeight: 180)
            } else if model.certificateChoices.isEmpty {
                ContentUnavailableView("No supported identities", systemImage: "person.text.rectangle",
                    description: Text("Insert your smart card and choose Refresh, or ask your administrator for a client identity in Keychain."))
            } else {
                List(model.certificateChoices, selection: $selectedID) { choice in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(choice.name).font(.body)
                        Text(choice.tokenID == nil ? "Keychain" : "Smart card or hardware token")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(choice.fingerprint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("SHA-256 fingerprint, \(choice.fingerprint)")
                    }
                    .padding(.vertical, 6)
                    .tag(choice.id)
                }
                .frame(minHeight: 180, idealHeight: 240, maxHeight: 360)
            }
            HStack {
                Button("Refresh") { model.loadCertificates() }.disabled(model.loadingCertificates || model.settingsLocked)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use certificate") {
                    guard let choice = model.certificateChoices.first(where: { $0.id == selectedID }) else { return }
                    guard model.selectCertificate(choice) else { return }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.settingsLocked || model.loadingCertificates || !model.certificateChoices.contains(where: { $0.id == selectedID }))
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

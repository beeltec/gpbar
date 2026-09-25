import SwiftUI

struct ConnectionPanel: View {
    @Bindable var model: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private var status: String {
        if model.preferences.portal.isEmpty { return "Set up VPN access" }
        if model.cleanupRequired { return "Cleanup needs attention" }
        switch model.phase {
        case .disconnected: return "Disconnected"
        case .preparing: return "Contacting your VPN"
        case .authenticating: return "Finish signing in"
        case .connecting: return "Starting your connection"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        case .failed: return "Connection stopped"
        case .unknown: return "Checking connection"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Menu {
                        ForEach(model.profiles.profiles) { profile in
                            Button { model.selectProfile(profile.id) } label: {
                                if profile.id == model.preferences.id {
                                    Label(model.profiles.label(for: profile), systemImage: "checkmark")
                                } else {
                                    Text(model.profiles.label(for: profile))
                                }
                            }
                            .disabled(model.profileControlsLocked)
                        }
                        Divider()
                        Button("Manage Connections…") { showWindow("connection") }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.connectionTitle).font(.headline).lineLimit(2)
                            if !model.connectionPortal.isEmpty {
                                Text(model.connectionPortal).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Connection profile")
                    .accessibilityValue("\(model.connectionTitle), \(model.connectionPortal)")
                    Spacer()
                    Button { showWindow("settings") } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                }
                ConnectionPath(phase: model.phase)
                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.system(size: 20, weight: .semibold, design: .rounded))
                    if let error = model.profiles.storageError ?? model.error {
                        Text(error).font(.callout).foregroundStyle(Color("Failure")).textSelection(.enabled)
                    } else if model.preferences.portal.isEmpty {
                        Text("Add the connection address supplied by your organization.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if !model.helperVerified {
                        Text(model.helperMessage).font(.callout).foregroundStyle(.secondary)
                    } else if let started = model.snapshot?.startedAtUnix, model.phase == .connected {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = max(0, Int(context.date.timeIntervalSince1970) - Int(started))
                            Text(String(format: "Connected for %02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if let snapshot = model.snapshot, model.phase == .connected {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        if let gateway = snapshot.gateway {
                            GridRow(alignment: .firstTextBaseline) {
                                Text("Gateway")
                                Text(gateway)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let address = snapshot.ipv4 {
                            GridRow(alignment: .firstTextBaseline) {
                                Text("VPN address")
                                Text(address)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.caption).textSelection(.enabled)
                }
                if model.phase == .connected {
                    if model.resourceAuthentication.request != nil {
                        Button("Open resource sign-in") { model.resourceAuthentication.reopen() }
                    }
                    if let message = model.resourceAuthenticationMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                primaryAction.controlSize(.large)
                if model.phase == .authenticating && model.sessionProfileKnown {
                    Button("Cancel sign-in") { model.disconnect() }.font(.caption)
                }
                Divider()
                HStack {
                    Button("Connections…") { showWindow("connection") }
                    Button("About GPBar…") { showWindow("about") }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 360).frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            model.authentication.onPresentWindow = { [dismiss] in dismiss() }
            model.refresh()
        }
        .onDisappear { model.authentication.onPresentWindow = nil }
    }

    @ViewBuilder private var primaryAction: some View {
        if model.hasSession {
            switch model.phase {
            case .preparing, .connecting:
                Button("Cancel") { model.disconnect() }
            case .authenticating where model.sessionProfileKnown:
                Button("Open sign-in window") { model.authentication.reopen() }.buttonStyle(.borderedProminent)
            case .disconnecting:
                Button("Disconnecting…") {}.disabled(true)
            case .unknown:
                HStack {
                    Button("Retry status") { model.refresh() }
                    Button("Disconnect") { model.disconnect() }
                }
            case .connected, .reconnecting, .disconnected, .failed, .authenticating:
                Button("Disconnect") { model.disconnect() }.buttonStyle(.borderedProminent)
            }
        } else if model.cleanupRequired {
            Button("Open recovery settings") { showWindow("settings") }
        } else if model.preferences.portal.isEmpty || model.profiles.storageError != nil {
            Button("Set up connection") { settings() }.buttonStyle(.borderedProminent)
        } else if !model.helperVerified || !model.engineAvailable {
            Button("Set up VPN helper") { showWindow("settings") }.buttonStyle(.borderedProminent)
        } else if model.phase == .unknown {
            Button("Retry status") { model.refresh() }
        } else if model.preferences.splitDNSError != nil {
            Button("Edit split DNS…") { settings() }.buttonStyle(.borderedProminent)
        } else {
            Button("Connect") { model.connect() }.buttonStyle(.borderedProminent)
                .disabled(model.profileControlsLocked)
        }
    }

    private func settings() { showWindow("connection") }

    private func showWindow(_ id: String) {
        dismiss()
        openWindow(id: id)
        NSApp.activate()
    }
}

import SwiftUI

struct ConnectionPanel: View {
    @Bindable var model: ConnectionModel
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
                    Text(model.preferences.title).font(.headline).lineLimit(2)
                    Spacer()
                    Button { settings() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("Connection settings").accessibilityLabel("Connection settings")
                }
                ConnectionPath(phase: model.phase)
                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.system(size: 20, weight: .semibold, design: .rounded))
                    if let error = model.error {
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
                primaryAction.controlSize(.large)
                if model.phase == .authenticating {
                    Button("Cancel sign-in") { model.disconnect() }.font(.caption)
                }
                Divider()
                HStack {
                    Button("About GPBar…") { openWindow(id: "about"); NSApp.activate() }
                    Spacer()
                    Button("Diagnostics…") { openWindow(id: "diagnostics"); NSApp.activate() }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 360).frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var primaryAction: some View {
        if model.cleanupRequired {
            Button("Open diagnostics") { openWindow(id: "diagnostics"); NSApp.activate() }
        } else if model.preferences.portal.isEmpty || !model.helperVerified || !model.engineAvailable {
            Button("Set up connection") { settings() }.buttonStyle(.borderedProminent)
        } else {
            switch model.phase {
            case .disconnected, .failed:
                Button("Connect") { model.connect() }.buttonStyle(.borderedProminent)
            case .preparing, .connecting:
                Button("Cancel") { model.disconnect() }
            case .authenticating:
                Button("Open sign-in window") { model.authentication.reopen() }.buttonStyle(.borderedProminent)
            case .connected, .reconnecting:
                Button("Disconnect") { model.disconnect() }.buttonStyle(.borderedProminent)
            case .disconnecting:
                Button("Disconnecting…") {}.disabled(true)
            case .unknown:
                Button("Retry status") { model.refresh() }
            }
        }
    }

    private func settings() { openWindow(id: "connection"); NSApp.activate() }
}

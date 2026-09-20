import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @Bindable var model: ConnectionModel
    @State private var removalPending = false
    @State private var exportText: String?
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection details").font(.system(size: 22, weight: .semibold, design: .rounded))
            LabeledContent("State", value: model.phase.rawValue.capitalized)
            LabeledContent("Helper", value: model.helperVerified ? "Verified" : "Not verified")
            if let snapshot = model.snapshot {
                LabeledContent("Portal", value: snapshot.portal)
                if let gateway = snapshot.gateway { LabeledContent("Gateway", value: gateway) }
                if let account = snapshot.account { LabeledContent("Account", value: account) }
                if let interface = snapshot.interface { LabeledContent("Interface", value: interface) }
                if let address = snapshot.ipv4 { LabeledContent("VPN address", value: address) }
            }
            if model.cleanupRequired || model.phase == .unknown {
                Text("GPClient restores only the network changes recorded for its sessions.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(model.recovering ? "Checking network…" : "Recover network") { model.recoverNetwork() }
                    .disabled(model.recovering || !model.helperVerified)
            }
            if let error = model.error { Text(error).foregroundStyle(Color("Failure")) }
            Divider()
            Text("Diagnostic export").font(.headline)
            Text("Review the text before saving. Portal addresses, accounts, network addresses, and sign-in secrets are excluded.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(model.diagnosticText).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 240)
            if let exportError { Text(exportError).foregroundStyle(Color("Failure")) }
            HStack {
                Button("Check helper") { model.refresh() }.disabled(model.checkingHelper)
                Button("Save diagnostics…") { saveDiagnostics() }
                Spacer()
                Button("Remove helper") {
                    removalPending = true
                    Task { await model.unregisterHelper(); removalPending = false }
                }
                .disabled(removalPending || model.helperStatus == .notRegistered || model.settingsLocked || model.cleanupRequired)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480)
        .textSelection(.enabled)
    }

    private func saveDiagnostics() {
        let text = model.diagnosticText
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "GPClient-diagnostics.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8); exportError = nil }
            catch { exportError = "The diagnostic file could not be saved. Choose another location." }
        }
    }
}

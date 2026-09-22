import SwiftUI

struct LoginSSOSettings: View {
    let state: LoginSSOState?
    let isBusy: Bool
    let message: String?
    let configure: (Bool) -> Void
    @State private var enabling = false

    var body: some View {
        Section {
            Text("Reuse your next macOS login password for this portal. Requires the same account and password on the VPN.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Only Automatic and Username and password use this option. It does not provide Kerberos or browser SSO.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let portal = state?.portal {
                Text("Enabled for \(portal)").font(.caption).textSelection(.enabled)
                Button("Disable macOS login SSO") { configure(false) }
            } else {
                Button("Enable macOS login SSO…") { enabling = true }
                if state?.installed == true {
                    Button("Retry removing unused login integration") { configure(false) }
                    Text("Other enrolled users must disable SSO before the system integration can be removed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isBusy { ProgressView().controlSize(.small) }
            if let guide = URL(string: "https://github.com/beeltec/gpbar/blob/main/LOGIN-SSO.md") {
                Link("Installation and recovery guide", destination: guide).font(.caption)
            }
        } header: { Text("macOS login SSO") }
        .confirmationDialog("Enable macOS login SSO?", isPresented: $enabling, titleVisibility: .visible) {
            Button("Enable for this portal") { configure(true) }
        } message: {
            Text("This installs a system login plug-in with administrator approval. It keeps your next login password in memory for five minutes. GPBar sends it once to the saved portal when you connect. Disable it before updating or removing GPBar.")
        }
    }
}

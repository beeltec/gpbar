import SwiftUI
import AppKit

struct GeneralSettings: View {
    @Bindable var model: ConnectionModel
    @ObservedObject var updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    @State private var removalPending = false
    @State private var reportPreview: DiagnosticReportPreview?

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

                Section {
                    LabeledContent("Status", value: model.helperDiagnostics.currentStatus)
                    LabeledContent("Network recovery required", value: model.cleanupRequired ? "Yes" : "No")
                    if let code = model.helperDiagnostics.currentCode {
                        Text(code.cause).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("App version", value: appVersion)
                    LabeledContent("Helper version", value: helperVersion)
                    LabeledContent("Helper protocol", value: model.helperDiagnostics.reportedProtocol.map(String.init) ?? "Unavailable")
                    LabeledContent("Last contact", value: model.helperDiagnostics.lastContact.map(HelperDiagnosticsState.date) ?? "Never during this app launch")
                    LabeledContent("Latest failure", value: latestFailure)
                    LabeledContent("Cached details", value: model.helperDiagnostics.cachedDetailsState)
                    if let issue = model.helperDiagnostics.installationIssue {
                        LabeledContent("Installation issue", value: issue.rawValue)
                        Text(issue.cause).font(.caption).foregroundStyle(.secondary)
                    }
                    if let received = model.helperDiagnostics.snapshotReceivedAt {
                        LabeledContent("Details received", value: HelperDiagnosticsState.date(received))
                    }
                    LabeledContent("App installation") {
                        Text(Bundle.main.bundleURL.path).textSelection(.enabled)
                            .lineLimit(nil).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Helper executable") {
                        Text(model.helperDiagnostics.snapshot?.executablePath ?? "Unavailable")
                            .textSelection(.enabled).lineLimit(nil).multilineTextAlignment(.trailing)
                    }
                    Text("Cause unknown means GPBar has no reliable cause. macOS may block startup or communication before the helper can reply.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("For more detail, reproduce the failure, note its time, and filter Console for GPBarHelper or com.beeltec.GPBar.helper. Review logs before sharing them.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Preview diagnostic report…") {
                        reportPreview = DiagnosticReportPreview(text: model.helperDiagnosticReport)
                    }
                } header: { Text("Helper diagnostics") }

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
        .sheet(item: $reportPreview) { preview in
            DiagnosticReportSheet(text: preview.text)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = HelperDiagnosticsState.safeVersion(info?["CFBundleShortVersionString"] as? String) ?? "Unavailable"
        let build = HelperDiagnosticsState.safeBuild(info?["CFBundleVersion"] as? String) ?? "Unavailable"
        return "\(version) (\(build))"
    }

    private var helperVersion: String {
        guard let snapshot = model.helperDiagnostics.snapshot else { return "Unavailable" }
        return "\(snapshot.version ?? "Unavailable") (\(snapshot.build ?? "Unavailable"))"
    }

    private var latestFailure: String {
        guard let failure = model.helperDiagnostics.lastFailure else { return "None during this app launch" }
        return "\(failure.code.rawValue) at \(HelperDiagnosticsState.date(failure.time))"
    }
}

private struct DiagnosticReportPreview: Identifiable {
    let id = UUID()
    let text: String
}

private struct DiagnosticReportSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostic report").font(.headline)
            Text("Review this report before copying or sharing it.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 350)
            HStack {
                if copied { Label("Report copied", systemImage: "checkmark.circle") }
                Spacer()
                Button("Close") { dismiss() }
                Button("Copy diagnostic report") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(text, forType: .string)
                    if copied {
                        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                            userInfo: [.announcement: "Diagnostic report copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 650)
        .frame(minHeight: 480)
    }
}

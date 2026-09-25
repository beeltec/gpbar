import Foundation

enum HelperDiagnosticCode: String {
    case approvalRequired = "approval_required"
    case notRegistered = "not_registered"
    case serviceNotFound = "service_not_found"
    case helperExecutableMissing = "helper_executable_missing"
    case helperNotExecutable = "helper_not_executable"
    case registrationFailed = "registration_failed"
    case removalFailed = "removal_failed"
    case signingIdentityUnavailable = "signing_identity_unavailable"
    case accessRejected = "access_rejected"
    case invalidRuntime = "invalid_runtime"
    case inspectionTimeout = "inspection_timeout"
    case commandTimeout = "command_timeout"
    case incompatibleProtocol = "incompatible_protocol"
    case transportUnavailable = "transport_unavailable"
    case invalidReply = "invalid_reply"
    case engineStartFailed = "engine_start_failed"
    case recoveryFailed = "recovery_failed"
    case unknownFailure = "unknown_failure"

    var title: String {
        switch self {
        case .approvalRequired: "Approval required"
        case .notRegistered: "Helper not installed"
        case .serviceNotFound: "Helper unavailable"
        case .helperExecutableMissing: "Cannot start helper"
        case .helperNotExecutable: "Cannot start helper"
        case .registrationFailed: "Helper setup failed"
        case .removalFailed: "Helper removal failed"
        case .signingIdentityUnavailable: "Signing identity unavailable"
        case .accessRejected: "Communication rejected"
        case .invalidRuntime: "Invalid helper runtime"
        case .inspectionTimeout: "Helper timed out"
        case .commandTimeout: "Helper command timed out"
        case .incompatibleProtocol: "Incompatible helper"
        case .transportUnavailable: "Helper unavailable"
        case .invalidReply: "Invalid helper reply"
        case .engineStartFailed: "Engine cannot start"
        case .recoveryFailed: "Network recovery failed"
        case .unknownFailure: "Helper failure"
        }
    }

    var cause: String {
        switch self {
        case .approvalRequired: "Approve GPBar in Login Items & Extensions."
        case .notRegistered: "Set up the helper in GPBar Settings."
        case .serviceNotFound: "Required service files are missing. Reinstall GPBar."
        case .helperExecutableMissing: "The bundled helper executable is missing. Reinstall GPBar."
        case .helperNotExecutable: "The bundled helper cannot execute. Reinstall GPBar."
        case .signingIdentityUnavailable: "GPBar could not read its signing identity."
        case .accessRejected: "The helper denied this user's access."
        case .invalidRuntime: "The helper reported an invalid root execution context."
        case .incompatibleProtocol: "The helper reported a different protocol version."
        case .engineStartFailed: "The helper reported that the VPN engine could not start."
        case .recoveryFailed: "Network recovery did not finish. Cause unknown. Check macOS logs near the failure time."
        case .registrationFailed, .removalFailed, .inspectionTimeout, .commandTimeout, .transportUnavailable, .invalidReply, .unknownFailure:
            "Cause unknown. Check macOS logs near the failure time."
        }
    }
}

struct HelperDiagnosticFailure {
    let code: HelperDiagnosticCode
    let time: Date
}

struct HelperDiagnosticsState {
    var currentStatus = "Checking helper"
    var currentCode: HelperDiagnosticCode?
    var lastFailure: HelperDiagnosticFailure?
    var lastContact: Date?
    var reportedProtocol: Int?
    var snapshot: HelperDiagnosticSnapshot?
    var snapshotReceivedAt: Date?
    var snapshotFresh = false
    var installationIssue: HelperDiagnosticCode?

    var cachedDetailsState: String {
        guard snapshot != nil else { return "Unavailable" }
        return snapshotFresh ? "Current" : "Stale"
    }

    mutating func contacted(_ reply: HelperReply) {
        lastContact = Date()
        reportedProtocol = reply.protocolVersion
        if let diagnostics = reply.diagnostics {
            snapshot = diagnostics
            snapshotReceivedAt = Date()
            snapshotFresh = true
        } else {
            snapshot = nil
            snapshotReceivedAt = nil
            snapshotFresh = false
        }
    }

    mutating func incompatibleProtocol(_ version: Int) {
        reportedProtocol = version
        failed(.incompatibleProtocol)
    }

    mutating func setInstallationIssue(_ code: HelperDiagnosticCode?) {
        guard installationIssue != code else { return }
        installationIssue = code
        if let code { lastFailure = HelperDiagnosticFailure(code: code, time: Date()) }
    }

    mutating func ready() {
        currentStatus = "Helper ready"
        currentCode = nil
    }

    mutating func failed(_ code: HelperDiagnosticCode) {
        currentStatus = code.title
        currentCode = code
        lastFailure = HelperDiagnosticFailure(code: code, time: Date())
        switch code {
        case .approvalRequired, .notRegistered, .serviceNotFound, .helperExecutableMissing,
             .helperNotExecutable, .signingIdentityUnavailable, .inspectionTimeout, .commandTimeout,
             .incompatibleProtocol, .transportUnavailable, .invalidReply:
            snapshotFresh = false
        default: break
        }
    }

    func report(serviceStatus: String, recoveryRequired: Bool) -> String {
        let appInfo = Bundle.main.infoDictionary
        let appVersion = Self.safeVersion(appInfo?["CFBundleShortVersionString"] as? String) ?? "unavailable"
        let appBuild = Self.safeBuild(appInfo?["CFBundleVersion"] as? String) ?? "unavailable"
        let helperVersion = snapshot?.version ?? "unavailable"
        let helperBuild = snapshot?.build ?? "unavailable"
        let path = Self.safePath(Bundle.main.bundleURL.path)
        let helperPath = snapshot?.executablePath.map(Self.safePath) ?? "unavailable"
        let failure = lastFailure.map { "\($0.code.rawValue) at \(Self.date($0.time))" } ?? "None during this app launch"
        let helperEvents = snapshot?.events.map {
            "\(Self.date($0.time)) \($0.kind.rawValue) \($0.reason?.rawValue ?? "")".trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n") ?? "Unavailable"
        return """
        GPBar helper diagnostic report, format 1
        Generated: \(Self.date(Date()))
        App: \(appVersion) (\(appBuild))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: arm64
        Service status: \(serviceStatus)
        Network recovery required: \(recoveryRequired ? "Yes" : "No")
        Current status: \(currentStatus)
        Current code: \(currentCode?.rawValue ?? "none")
        Cause: \(currentCode?.cause ?? "No current failure")
        Installation issue: \(installationIssue?.rawValue ?? "none")
        App installation: \(path)
        Helper executable: \(helperPath)
        Helper version: \(helperVersion) (\(helperBuild))
        Helper protocol: \(reportedProtocol.map(String.init) ?? "unavailable")
        Last successful contact: \(lastContact.map(Self.date) ?? "Never during this app launch")
        Latest failure: \(failure)
        Cached helper details: \(cachedDetailsState)\(snapshotReceivedAt.map { ", last received " + Self.date($0) } ?? "")

        Recent helper events (current helper process only, at most 100):
        \(helperEvents.isEmpty ? "None" : helperEvents)

        App observations cover this app launch only. Helper events reset when the helper restarts.
        Paths in this copy hide user homes and custom installation directories.
        GPBar does not collect raw macOS logs in this report.
        If the cause is unknown, reproduce the failure and note its time. In Console, filter for GPBarHelper or com.beeltec.GPBar.helper.
        launchd and security messages near that time may explain failures before the helper can reply.
        You can also run:
        log show --last 10m --style compact --predicate 'subsystem == "com.beeltec.GPBar.helper" OR process == "GPBarHelper" OR ((process == "launchd" OR process == "amfid" OR process == "syspolicyd") AND eventMessage CONTAINS[c] "com.beeltec.GPBar.helper")'
        Inspect macOS logs before sharing them. They may contain private details.
        """
    }

    static func date(_ value: Date) -> String { value.ISO8601Format() }

    static func safeVersion(_ value: String?) -> String? {
        value.flatMap { HelperDiagnosticSnapshot.validVersion($0) ? $0 : nil }
    }

    static func safeBuild(_ value: String?) -> String? {
        value.flatMap { HelperDiagnosticSnapshot.validBuild($0) ? $0 : nil }
    }

    static func safePath(_ path: String) -> String {
        let pieces = path.split(separator: "/").map(String.init)
        guard let index = pieces.firstIndex(of: "GPBar.app") else { return "<redacted>" }
        let suffix = pieces.dropFirst(index + 1)
        guard suffix.isEmpty || suffix == ["Contents", "MacOS", "GPBarHelper"] else { return "<redacted>" }
        let base: String
        if pieces.prefix(index) == ["Applications"] { base = "/Applications/GPBar.app" }
        else if pieces.first == "Users" { base = "~/.../GPBar.app" }
        else { base = "<redacted>/GPBar.app" }
        return base + (suffix.isEmpty ? "" : "/" + suffix.joined(separator: "/"))
    }
}

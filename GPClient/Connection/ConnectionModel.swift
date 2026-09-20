import AppKit
import Observation
import ServiceManagement
import Network

@MainActor @Observable final class ConnectionModel {
    let preferences = ConnectionPreferences()
    let authentication = AuthenticationCoordinator()
    private(set) var phase: ConnectionPhase = .unknown
    private(set) var snapshot: ConnectionSnapshot?
    private(set) var cleanupRequired = false
    private(set) var engineAvailable = false
    private var sessionID: String?
    private var startPending = false
    private var lastSequence: UInt64 = 0
    private var completedSessions: [String] = []
    private var quitAfterDisconnect = false
    private var quitTimeout: Task<Void, Never>?
    private var retryExternally = false
    private var browserOverride: BrowserChoice?
    private let pathMonitor = NWPathMonitor()
    private(set) var recovering = false
    private(set) var recentEvents: [String] = []
    var settingsLocked: Bool { sessionID != nil || phase.isActive }

    init() {
        helper.onEvent = { [weak self] event in self?.receive(event) }
        helper.onInterruption = { [weak self] in
            guard let self else { return }
            self.cancelPendingQuit()
            self.helperVerified = false
            self.lastSequence = 0
            if self.sessionID != nil { self.phase = .unknown }
        }
        preferences.onAddressChange = { [weak self] in
            guard let self, !self.settingsLocked else { return }
            self.snapshot = nil
            self.error = nil
            self.authentication.finish()
        }
        authentication.onCancel = { [weak self] in self?.disconnect() }
        authentication.onRetryExternally = { [weak self] in
            guard let self else { return }
            self.retryExternally = true
            self.disconnect()
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionID != nil else { return }
                self.refresh()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.beelte.gpclient.network-path"))
        authentication.onCallback = { [weak self] sessionID, challengeID, callback in
            guard let self, self.sessionID == sessionID else { return }
            self.send(EngineCommand(type: .submitCallback, challengeID: challengeID, callback: callback))
        }
        authentication.onOTP = { [weak self] sessionID, challengeID, otp in
            guard let self, self.sessionID == sessionID else { return }
            self.send(EngineCommand(type: .submitOtp, challengeID: challengeID, otp: otp))
        }
    }

    func connect(browserOverride: BrowserChoice? = nil) {
        guard !settingsLocked, !cleanupRequired else { return }
        guard preferences.saveAddress() else { error = preferences.addressError; return }
        guard helperVerified, engineAvailable else { error = "Set up the current VPN helper before connecting."; return }
        sessionID = UUID().uuidString
        self.browserOverride = browserOverride
        startPending = true
        lastSequence = 0
        error = nil
        snapshot = nil
        phase = .preparing
        send(EngineCommand(type: .start, portal: preferences.portal, reconnect: preferences.reconnect))
    }

    func disconnect() {
        guard sessionID != nil, phase != .disconnecting else { return }
        phase = .disconnecting
        authentication.finish()
        send(EngineCommand(type: .disconnect))
    }

    func disconnectAndQuit() {
        guard sessionID != nil else {
            Task { NSApp.reply(toApplicationShouldTerminate: false) }
            refresh()
            return
        }
        quitAfterDisconnect = true
        quitTimeout?.cancel()
        quitTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            self?.cancelPendingQuit()
        }
        disconnect()
    }

    private func cancelPendingQuit() {
        quitTimeout?.cancel()
        quitTimeout = nil
        if quitAfterDisconnect {
            quitAfterDisconnect = false
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    private func send(_ command: EngineCommand) {
        guard let sessionID else { return }
        let envelope = EngineCommandEnvelope(protocolVersion: helperProtocolVersion, sessionID: sessionID,
            commandID: UUID().uuidString, command: command)
        helper.send(envelope) { [weak self] reply in
            guard let self, self.sessionID == sessionID else { return }
            if command.type == .start { self.startPending = false }
            guard !reply.accepted else { return }
            self.cancelPendingQuit()
            if reply.code == "command_timeout" || reply.code == "helper_unavailable" {
                self.phase = .unknown
                self.error = "Connection status is unavailable. Check the helper before starting another session."
            } else if command.type == .start {
                self.phase = .failed
                self.sessionID = nil
                self.error = reply.code == "runtime_or_recovery"
                    ? "The VPN runtime could not be verified, or an earlier session needs network recovery. Open diagnostics."
                    : "The VPN session could not start. Check helper access and try again."
            } else {
                if command.type == .disconnect || command.type == .cancel || command.type == .getSnapshot {
                    self.phase = .unknown
                }
                self.error = "The command was rejected. Cancel this attempt and try again."
            }
        }
    }

    private func receive(_ envelope: EngineEventEnvelope) {
        guard UUID(uuidString: envelope.sessionID) != nil, !completedSessions.contains(envelope.sessionID) else { return }
        if sessionID == nil {
            guard envelope.event.type == .snapshot || envelope.event.type == .phaseChanged
                    || envelope.event.type == .authenticationRequired || envelope.event.type == .otpRequired
                    || envelope.event.type == .stopped else { return }
            sessionID = envelope.sessionID
            lastSequence = 0
        }
        guard sessionID == envelope.sessionID, envelope.sequence > lastSequence else { return }
        lastSequence = envelope.sequence
        let event = envelope.event
        recentEvents.append("\(Date().ISO8601Format()) \(event.type.rawValue)\(event.phase.map { " " + $0.rawValue } ?? "")")
        if let code = event.code, code.count <= 128, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            recentEvents[recentEvents.count - 1] += " " + code
        }
        if recentEvents.count > 100 { recentEvents.removeFirst() }
        switch event.type {
        case .phaseChanged:
            if let phase = event.phase {
                self.phase = phase
                if phase != .authenticating && phase != .unknown { authentication.finish() }
                if phase == .connected { error = nil }
            }
        case .snapshot:
            if let snapshot = event.snapshot {
                self.snapshot = snapshot
                phase = snapshot.phase
                if phase != .authenticating && phase != .unknown { authentication.finish() }
                if phase == .connected { error = nil }
            }
        case .authenticationRequired, .otpRequired:
            phase = .authenticating
            authentication.begin(sessionID: envelope.sessionID, event: event, preferences: preferences, browserOverride: browserOverride)
        case .authenticationCompleted:
            authentication.complete(challengeID: event.challengeID)
        case .failure:
            error = event.message ?? "The VPN session could not finish."
            if event.code == "engine_exit" {
                phase = .unknown
                cleanupRequired = true
                authentication.finish()
            }
        case .stopped:
            startPending = false
            completedSessions.append(envelope.sessionID)
            if completedSessions.count > 16 { completedSessions.removeFirst() }
            cleanupRequired = event.cleanup != "not_needed" && event.cleanup != "restored"
            sessionID = nil
            authentication.finish()
            phase = error == nil && !cleanupRequired ? .disconnected : .failed
            if cleanupRequired { error = "Connection stopped. Network cleanup needs attention." }
            if quitAfterDisconnect {
                quitTimeout?.cancel()
                quitTimeout = nil
                quitAfterDisconnect = false
                NSApp.reply(toApplicationShouldTerminate: !cleanupRequired)
            } else if retryExternally {
                retryExternally = false
                if !cleanupRequired { connect(browserOverride: .systemDefault) }
            }
        case .ready: break
        }
    }
    private let helper = HelperClient()
    private let service = SMAppService.daemon(plistName: "com.beelte.gpclient.helper.plist")
    private(set) var helperStatus: SMAppService.Status = .notRegistered
    private(set) var helperMessage = "The helper needs your permission to manage VPN connections."
    private(set) var helperVerified = false
    private(set) var checkingHelper = false
    var error: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    func refresh() {
        helperStatus = service.status
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard helperStatus == .enabled else {
            if sessionID != nil { phase = .unknown }
            cancelPendingQuit()
            helper.cancel()
            checkingHelper = false
            if sessionID == nil && phase == .unknown { phase = .disconnected }
            helperVerified = false
            helperMessage = helperStatus == .requiresApproval
                ? "Allow GPClient in Login Items & Extensions, then return here."
                : "The helper needs your permission to manage VPN connections."
            return
        }
        guard !checkingHelper, !startPending else { return }
        checkingHelper = true
        let inspectedSessionID = sessionID
        helper.inspect { [weak self] result in
            guard let self else { return }
            self.checkingHelper = false
            guard self.service.status == .enabled else {
                self.refresh()
                return
            }
            guard self.sessionID == inspectedSessionID else {
                self.refresh()
                return
            }
            switch result {
            case .success(let reply):
                self.helperVerified = reply.runningAsRoot && reply.authorizedUser
                guard self.helperVerified else {
                    self.engineAvailable = false
                    if self.sessionID != nil { self.phase = .unknown }
                    self.helperMessage = "The helper could not confirm access for this user."
                    return
                }
                self.engineAvailable = reply.engineSessionsAvailable && !reply.sessionBusy
                if reply.recoveryRequired {
                    self.cleanupRequired = true
                    self.phase = .failed
                    self.error = "An earlier VPN session needs network recovery. Open diagnostics."
                }
                if reply.sessionBusy {
                    self.phase = .unknown
                    self.helperMessage = "Another user's VPN session is stopping. Check again shortly."
                    return
                }
                if reply.activeSessionID == nil && self.sessionID != nil && !self.startPending {
                    self.sessionID = nil
                    self.lastSequence = 0
                    self.snapshot = nil
                    self.authentication.finish()
                    self.cancelPendingQuit()
                    self.phase = self.cleanupRequired || self.error != nil ? .failed : .disconnected
                }
                if self.sessionID == nil {
                    if let active = reply.activeSessionID, !self.completedSessions.contains(active) {
                        self.sessionID = active
                        self.phase = .unknown
                    } else if self.phase == .unknown { self.phase = .disconnected }
                }
                if self.sessionID != nil { self.send(EngineCommand(type: .getSnapshot)) }
                self.helperMessage = "Helper identity and user access verified."
            case .failure:
                self.helperVerified = false
                self.helperMessage = "The helper could not be reached. Check approval, then try again."
            }
        }
    }

    func registerHelper() {
        do {
            try service.register()
            error = nil
            refresh()
        } catch {
            refresh()
            self.error = helperStatus == .requiresApproval ? nil
                : "Helper setup did not finish. Open Login Items & Extensions to check access."
        }
    }

    func unregisterHelper() async {
        guard !settingsLocked, !cleanupRequired else { return }
        helper.cancel()
        helperVerified = false
        do {
            try await service.unregister()
            error = nil
            refresh()
        } catch {
            self.error = "The helper could not be removed. Try again after checking System Settings."
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func recoverNetwork() {
        guard helperVerified, !recovering, sessionID == nil || phase == .unknown else { return }
        recovering = true
        let request = EngineCommandEnvelope(protocolVersion: helperProtocolVersion, sessionID: UUID().uuidString,
            commandID: UUID().uuidString, command: EngineCommand(type: .recoverNetwork))
        helper.send(request) { [weak self] reply in
            guard let self else { return }
            self.recovering = false
            if reply.accepted {
                self.startPending = false
                if let sessionID = self.sessionID { self.completedSessions.append(sessionID) }
                self.sessionID = nil
                self.cleanupRequired = false
                self.phase = .disconnected
                self.error = nil
                self.authentication.finish()
            } else {
                self.error = "Network recovery could not finish. A session may still be running. Wait, then check again."
            }
        }
    }

    var diagnosticText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return """
        GPClient \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: arm64
        State: \(phase.rawValue)
        Helper verified: \(helperVerified)
        Network recovery required: \(cleanupRequired)
        Protocol: \(helperProtocolVersion)

        Recent session events
        \(recentEvents.joined(separator: "\n"))
        """
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Launch at login could not be changed. Check Login Items & Extensions."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var installedBrowsers: [URL] {
        guard let url = URL(string: "https://example.com") else { return [] }
        var identifiers = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: url).filter {
            guard let identifier = Bundle(url: $0)?.bundleIdentifier else { return false }
            return identifiers.insert(identifier).inserted
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

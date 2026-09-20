import Foundation
import Darwin
import SystemConfiguration

actor SessionController {
    static let shared = SessionController()
    private let writeQueue = DispatchQueue(label: "com.beeltec.GPBar.engine-input")
    private var pendingWrites = 0
    private var finishing = false
    private var completed: (uid_t, Data)?
    private var startupTask: Task<Void, Never>?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var engineURL: URL?
    private var owner: uid_t?
    private var sessionPortal: String?
    private var pendingAuthenticationUpdates: [uid_t: [String: AuthenticationCacheUpdate]] = [:]
    private var sessionID: String?
    private var observer: (@Sendable (Data) -> Void)?
    private var observerID: UUID?
    private var observerUser: uid_t?
    private var pendingStart: Data?
    private var sequence: UInt64 = 0
    private var lastSnapshot: EngineEventEnvelope?
    private var challenge: EngineEventEnvelope?
    private var signatureRequest: EngineEventEnvelope?
    private var terminal: EngineEventEnvelope?
    private var exitCode: Int32?
    private var stdoutEnded = false
    private var networkMayHaveChanged = false
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var lifetimeTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?
    private var uiLossTask: Task<Void, Never>?

    func attach(userID: uid_t, connectionID: UUID, observer: @escaping @Sendable (Data) -> Void) -> (sessionID: String?, busy: Bool, recoveryRequired: Bool, pendingAuthenticationUpdates: [AuthenticationCacheUpdate]) {
        let pending = Array(pendingAuthenticationUpdates[userID, default: [:]].values)
        guard owner == nil || owner == userID else { return (nil, true, false, pending) }
        self.observer = observer
        observerID = connectionID
        observerUser = userID
        uiLossTask?.cancel()
        if let completed, completed.0 == userID { observer(completed.1) }
        if let challenge, let bytes = try? JSONEncoder().encode(challenge) { observer(bytes) }
        if let signatureRequest, let bytes = try? JSONEncoder().encode(signatureRequest) { observer(bytes) }
        if let lastSnapshot, let bytes = try? JSONEncoder().encode(lastSnapshot) { observer(bytes) }
        let recoveryRequired = sessionID == nil && ((try? SecureRuntime.hasPendingSessions()) ?? true)
        return (sessionID, false, recoveryRequired, pending)
    }

    func detach(connectionID: UUID) {
        guard observerID == connectionID else { return }
        observer = nil
        observerID = nil
        observerUser = nil
        if challenge != nil || signatureRequest != nil {
            uiLossTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.stop()
            }
        }
    }

    func send(_ bytes: Data, userID: uid_t) async -> CommandReply {
        guard bytes.count <= maximumMessageBytes,
              let message = try? JSONDecoder().decode(EngineCommandEnvelope.self, from: bytes),
              message.protocolVersion == helperProtocolVersion,
              UUID(uuidString: message.sessionID) != nil,
              UUID(uuidString: message.commandID) != nil else { return CommandReply(accepted: false, code: "invalid_command") }
        if message.command.type == .acknowledgeAuthenticationCache {
            guard currentConsoleUser() == userID, let portal = message.command.portal,
                  let revision = message.command.cacheRevision else {
                return CommandReply(accepted: false, code: "invalid_cache_acknowledgement")
            }
            if pendingAuthenticationUpdates[userID]?[portal]?.revision == revision {
                pendingAuthenticationUpdates[userID]?.removeValue(forKey: portal)
                if pendingAuthenticationUpdates[userID]?.isEmpty == true {
                    pendingAuthenticationUpdates.removeValue(forKey: userID)
                }
            }
            return CommandReply(accepted: true, code: nil)
        }
        if message.command.type == .recoverNetwork {
            guard process == nil, sessionID == nil, !finishing, currentConsoleUser() == userID else {
                return CommandReply(accepted: false, code: "session_active")
            }
            finishing = true
            let success = await Task.detached {
                do { try SecureRuntime.recoverInactiveSessions(); return true } catch { return false }
            }.value
            finishing = false
            if success { completed = nil }
            return CommandReply(accepted: success, code: success ? nil : "recovery_required")
        }
        if message.command.type == .start {
            guard process == nil, sessionID == nil, !finishing, currentConsoleUser() == userID, observerUser == userID,
                  let portal = message.command.portal, let normalized = PortalAddress.normalize(portal), normalized == portal,
                  message.command.reconnect != nil else { return CommandReply(accepted: false, code: "start_rejected") }
            guard message.command.identity?.isValid != false,
                  message.command.certificateOnly != true || message.command.identity != nil,
                  message.command.certificateUsername.map({ $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) != false else {
                return CommandReply(accepted: false, code: "invalid_identity")
            }
            guard message.command.savedAuthentication.map({ message.command.rememberAuthentication == true && $0.isValid && $0.portal == portal }) != false else {
                return CommandReply(accepted: false, code: "invalid_saved_authentication")
            }
            guard message.command.savedAuthentication == nil || pendingAuthenticationUpdates[userID]?[portal] == nil else {
                return CommandReply(accepted: false, code: "authentication_cache_unconfirmed")
            }
            guard pendingAuthenticationUpdates[userID, default: [:]].count < 128
                    || pendingAuthenticationUpdates[userID]?[portal] != nil else {
                return CommandReply(accepted: false, code: "authentication_cache_cleanup_required")
            }
            owner = userID
            sessionPortal = portal
            completed = nil
            sessionID = message.sessionID
            do {
                try start(bytes)
                return CommandReply(accepted: true, code: nil)
            } catch {
                owner = nil
                sessionPortal = nil
                sessionID = nil
                return CommandReply(accepted: false, code: error is SecureRuntime.RuntimeError ? "runtime_or_recovery" : "engine_start_failed")
            }
        }
        guard owner == userID, sessionID == message.sessionID else {
            return CommandReply(accepted: false, code: "session_not_owned")
        }
        if message.command.type == .cancel || message.command.type == .disconnect {
            await stop()
            return CommandReply(accepted: true, code: nil)
        }
        guard currentConsoleUser() == userID else { return CommandReply(accepted: false, code: "user_not_active") }
        if message.command.type == .getSnapshot && (pendingStart != nil || finishing) {
            if let lastSnapshot, let bytes = try? JSONEncoder().encode(lastSnapshot) { emit(bytes) }
            return CommandReply(accepted: true, code: nil)
        }
        if message.command.type == .submitCredentials {
            guard let username = message.command.username, !username.isEmpty, username.utf8.count <= 1024,
                  !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let password = message.command.password, !password.isEmpty, password.utf8.count <= 4096 else {
                return CommandReply(accepted: false, code: "invalid_credentials")
            }
        }
        if message.command.type == .submitSignature {
            guard let signatureRequest, message.command.requestID == signatureRequest.event.requestID,
                  message.command.signature.map({ !$0.isEmpty && $0.count <= 1024 }) != false else {
                return CommandReply(accepted: false, code: "signature_expired")
            }
            self.signatureRequest = nil
        }
        if message.command.type == .submitCallback || message.command.type == .submitOtp || message.command.type == .submitCredentials {
            guard let challenge, message.command.challengeID == challenge.event.challengeID,
                  (message.command.type == .submitCallback && challenge.event.type == .authenticationRequired && message.command.callback != nil)
                    || (message.command.type == .submitOtp && challenge.event.type == .otpRequired && message.command.otp != nil)
                    || (message.command.type == .submitCredentials && challenge.event.type == .credentialsRequired) else {
                return CommandReply(accepted: false, code: "challenge_expired")
            }
            self.challenge = nil
        }
        do { try await write(bytes); return CommandReply(accepted: true, code: nil) }
        catch { await stop(); return CommandReply(accepted: false, code: "engine_unavailable") }
    }

    private func start(_ start: Data) throws {
        guard let sessionID else { throw ControllerError.invalidState }
        let engine = try SecureRuntime.prepare(sessionID: sessionID)
        guard currentConsoleUser() == owner else {
            try? SecureRuntime.removeUnusedSession(engine: engine)
            throw ControllerError.invalidState
        }
        let child = Process()
        let commandPipe = Pipe()
        let eventPipe = Pipe()
        let diagnosticPipe = Pipe()
        child.executableURL = engine
        child.arguments = ["app-session"]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": SecureRuntime.directory.path,
                             "LANG": "en_US.UTF-8", "GPBAR_APP_SESSION": "1",
                             "GNUTLS_SYSTEM_PRIORITY_FILE": "/dev/null"]
        child.currentDirectoryURL = SecureRuntime.directory
        child.standardInput = commandPipe
        child.standardOutput = eventPipe
        child.standardError = diagnosticPipe
        child.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { await self?.exited(code) }
        }
        do {
            try child.run()
            try SecureRuntime.recordProcess(child.processIdentifier, engine: engine)
        }
        catch {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? SecureRuntime.removeUnusedSession(engine: engine)
            throw error
        }
        try? commandPipe.fileHandleForReading.close()
        try? eventPipe.fileHandleForWriting.close()
        try? diagnosticPipe.fileHandleForWriting.close()
        process = child
        engineURL = engine
        input = commandPipe.fileHandleForWriting
        output = eventPipe.fileHandleForReading
        errorOutput = diagnosticPipe.fileHandleForReading
        pendingStart = start
        sequence = 0
        terminal = nil
        lastSnapshot = nil
        challenge = nil
        signatureRequest = nil
        exitCode = nil
        stdoutEnded = false
        networkMayHaveChanged = true
        startupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await self?.stop()
        }
        let events = Self.chunks(eventPipe.fileHandleForReading)
        let errors = Self.chunks(diagnosticPipe.fileHandleForReading)
        outputTask = Task { [weak self] in
            do {
                var buffer = Data()
                for try await chunk in events {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        guard newline <= maximumMessageBytes else { throw ControllerError.invalidFrame }
                        let frame = buffer.subdata(in: 0..<newline)
                        buffer.removeSubrange(0...newline)
                        try await self?.receive(frame)
                    }
                    guard buffer.count <= maximumMessageBytes else { throw ControllerError.invalidFrame }
                }
                if !buffer.isEmpty { throw ControllerError.invalidFrame }
            } catch { await self?.stop() }
            await self?.outputEnded()
        }
        errorTask = Task {
            do { for try await _ in errors {} } catch {}
        }
        lifetimeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await self?.checkConsoleUser()
            }
        }
    }

    private nonisolated static func chunks(_ handle: FileHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            handle.readabilityHandler = { handle in
                do {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { return }
                    guard count >= 0 else { throw ControllerError.invalidFrame }
                    guard count > 0 else {
                        handle.readabilityHandler = nil
                        continuation.finish()
                        return
                    }
                    if case .dropped = continuation.yield(Data(buffer.prefix(count))) {
                        handle.readabilityHandler = nil
                        continuation.finish(throwing: ControllerError.invalidFrame)
                    }
                } catch {
                    handle.readabilityHandler = nil
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    private func receive(_ bytes: Data) async throws {
        guard let event = try? JSONDecoder().decode(EngineEventEnvelope.self, from: bytes),
              event.protocolVersion == helperProtocolVersion, sequence < UInt64.max - 1, event.sequence == sequence + 1 else {
            throw ControllerError.invalidFrame
        }
        sequence = event.sequence
        if event.event.type == .ready {
            guard event.sessionID.isEmpty, event.event.openconnectVersion != nil, let start = pendingStart else {
                throw ControllerError.invalidFrame
            }
            pendingStart = nil
            startupTask?.cancel()
            startupTask = nil
            try await write(start)
            return
        }
        guard event.sessionID == sessionID else { throw ControllerError.invalidFrame }
        if event.event.type == .phaseChanged && [.connecting, .connected, .reconnecting].contains(event.event.phase) {
            networkMayHaveChanged = true
        }
        switch event.event.type {
        case .authenticationCacheChanged:
            guard let owner, let portal = sessionPortal else { throw ControllerError.invalidFrame }
            let update = AuthenticationCacheUpdate(portal: portal, revision: UUID())
            pendingAuthenticationUpdates[owner, default: [:]][portal] = update
            var payload = event.event
            if payload.savedAuthentication.map({ $0.isValid && $0.portal == portal }) == false {
                payload.savedAuthentication = nil
            }
            payload.server = portal
            payload.cacheRevision = update.revision
            let delivery = EngineEventEnvelope(protocolVersion: event.protocolVersion, sessionID: event.sessionID,
                sequence: event.sequence, event: payload)
            emit(try JSONEncoder().encode(delivery))
            return
        case .signatureRequired:
            guard let requestID = event.event.requestID, !requestID.isEmpty, requestID.utf8.count <= 64,
                  requestID.allSatisfy({ $0.isHexDigit }), event.event.scheme != nil, event.event.digest != nil,
                  let input = event.event.input, !input.isEmpty, input.count <= 65536 else {
                throw ControllerError.invalidFrame
            }
            signatureRequest = event
        case .authenticationRequired, .otpRequired, .credentialsRequired:
            guard event.event.challengeID != nil else { throw ControllerError.invalidFrame }
            challenge = event
        case .authenticationCompleted:
            challenge = nil
        case .snapshot, .phaseChanged:
            lastSnapshot = event
        case .stopped:
            terminal = event
            networkMayHaveChanged = event.event.cleanup != "not_needed"
            challenge = nil
            signatureRequest = nil
        default: break
        }
        if event.event.type != .stopped { emit(bytes) }
    }

    private func emit(_ bytes: Data) {
        guard owner != nil, observerUser == owner else { return }
        observer?(bytes)
    }

    private func write(_ data: Data) async throws {
        guard data.count < maximumMessageBytes, let input, process?.isRunning == true else { throw ControllerError.invalidState }
        guard pendingWrites < 4 else { throw ControllerError.invalidState }
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        var frame = data
        frame.append(10)
        let bytes = frame
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do { try input.write(contentsOf: bytes); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func stop() async {
        guard let sessionID, let process, process.isRunning else { return }
        if let engineURL { try? SecureRuntime.cancelNetworkWork(engine: engineURL) }
        if escalationTask == nil {
            escalationTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.terminateOwnedProcess()
            }
        }
        let command = EngineCommandEnvelope(protocolVersion: helperProtocolVersion, sessionID: sessionID,
            commandID: UUID().uuidString, command: EngineCommand(type: .disconnect))
        if let bytes = try? JSONEncoder().encode(command) { try? await write(bytes) }
    }

    private func terminateOwnedProcess() async {
        guard let process, process.isRunning else { return }
        process.terminate()
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func checkConsoleUser() async {
        if let owner, currentConsoleUser() != owner { await stop() }
    }

    private func currentConsoleUser() -> uid_t? {
        var user: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &user, nil) != nil, user != 0 else { return nil }
        return user
    }

    private func exited(_ code: Int32) async {
        exitCode = code
        await finishIfDrained()
    }

    private func outputEnded() async {
        stdoutEnded = true
        await finishIfDrained()
    }

    private func finishIfDrained() async {
        guard stdoutEnded, exitCode != nil, !finishing else { return }
        finishing = true
        startupTask?.cancel()
        lifetimeTask?.cancel()
        escalationTask?.cancel()
        uiLossTask?.cancel()
        errorTask?.cancel()
        for handle in [input, output, errorOutput] { try? handle?.close() }
        input = nil
        output = nil
        errorOutput = nil
        process = nil
        challenge = nil
        signatureRequest = nil
        if let sessionID {
            sequence += 1
            let state = EngineEventEnvelope(protocolVersion: helperProtocolVersion, sessionID: sessionID, sequence: sequence,
                event: EngineEvent(type: .phaseChanged, phase: terminal == nil ? .unknown : .disconnecting))
            lastSnapshot = state
            if let bytes = try? JSONEncoder().encode(state) { emit(bytes) }
        }
        let recovered: Bool
        if let engineURL {
            recovered = await Task.detached {
                do { try SecureRuntime.recover(engine: engineURL); try SecureRuntime.removeUnusedSession(engine: engineURL); return true }
                catch { return false }
            }.value
        } else { recovered = false }
        if let sessionID, let owner {
            if terminal == nil {
                sequence += 1
                let failure = EngineEventEnvelope(protocolVersion: helperProtocolVersion, sessionID: sessionID, sequence: sequence,
                    event: EngineEvent(type: .failure, message: recovered ? "The VPN engine stopped unexpectedly. Network changes were removed." : "The VPN engine stopped unexpectedly. Network cleanup needs attention.", code: "engine_exit", retryable: recovered))
                if let bytes = try? JSONEncoder().encode(failure) { emit(bytes) }
            }
            sequence += 1
            let stopped = EngineEventEnvelope(protocolVersion: helperProtocolVersion, sessionID: sessionID, sequence: sequence,
                event: EngineEvent(type: .stopped, cleanup: recovered ? "restored" : "unverified"))
            if let bytes = try? JSONEncoder().encode(stopped) {
                completed = (owner, bytes)
                emit(bytes)
            }
        }
        sessionID = nil
        owner = nil
        sessionPortal = nil
        lastSnapshot = nil
        challenge = nil
        signatureRequest = nil
        terminal = nil
        engineURL = nil
        pendingStart = nil
        finishing = false
        lifetimeTask = nil
        escalationTask = nil
        uiLossTask = nil
    }

    enum ControllerError: Error { case invalidState, invalidFrame }
}

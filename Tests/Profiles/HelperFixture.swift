import Foundation

@MainActor final class SMAppService {
    enum Status { case enabled, notRegistered, requiresApproval }
    static let mainApp = SMAppService()
    static let fixture = SMAppService()
    var status = Status.enabled
    static func daemon(plistName: String) -> SMAppService { fixture }
    static func openSystemSettingsLoginItems() {}
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
}

@MainActor final class HelperClient {
    enum HelperError: Error { case unavailable }
    static var latest: HelperClient?
    var onEvent: ((EngineEventEnvelope) -> Void)?
    var onInterruption: (() -> Void)?
    var inspection: ((Result<HelperReply, HelperError>) -> Void)?
    var commands: [EngineCommandEnvelope] = []
    var deferCommands = false
    var replies: [(CommandReply) -> Void] = []
    init() { Self.latest = self }
    func inspect(completion: @escaping (Result<HelperReply, HelperError>) -> Void) { inspection = completion }
    func cancel() {}
    func send(_ command: EngineCommandEnvelope, completion: @escaping (CommandReply) -> Void) {
        commands.append(command)
        if deferCommands { replies.append(completion) }
        else { completion(CommandReply(accepted: true, code: nil)) }
    }
    func prepareForUpdate() async -> Bool { true }
    func configureLoginSSO(portal: String?, authorization: Data) async -> Bool { true }
    func reply(active: String? = nil, cleanup: Bool = false, policies: [KerberosPolicyUpdate] = [],
               updates: [AuthenticationCacheUpdate] = [], loginPortal: String? = nil) {
        let completion = inspection
        inspection = nil
        completion?(.success(HelperReply(protocolVersion: helperProtocolVersion, commandID: UUID(),
            runningAsRoot: true, authorizedUser: true, engineSessionsAvailable: true, activeSessionID: active,
            sessionBusy: false, recoveryRequired: cleanup, pendingAuthenticationUpdates: updates,
            pendingKerberosPolicies: policies, loginSSO: LoginSSOState(installed: loginPortal != nil, portal: loginPortal))))
    }
    func event(_ kind: EngineEvent.Kind, session: String, sequence: UInt64, phase: ConnectionPhase? = nil,
               portal: String? = nil, cleanup: String? = nil, saved: SavedAuthentication? = nil) {
        var payload = EngineEvent(type: kind, phase: phase)
        payload.server = portal
        payload.cleanup = cleanup
        payload.savedAuthentication = saved
        if kind == .authenticationCacheChanged { payload.cacheRevision = UUID() }
        onEvent?(EngineEventEnvelope(protocolVersion: helperProtocolVersion, sessionID: session, sequence: sequence, event: payload))
    }
}

@MainActor enum KeychainAuthentication {
    enum Failure: Error { case unavailable }
    struct Write {
        let portal: String
        let namespace: UUID?
        let saved: SavedAuthentication?
        let completion: @Sendable (Bool) -> Void
    }
    static var writes: [Write] = []
    static var loads: [@Sendable (Result<SavedAuthentication?, Failure>) -> Void] = []
    static func load(portal: String, namespace: UUID? = nil, completion: @escaping @Sendable (Result<SavedAuthentication?, Failure>) -> Void) {
        loads.append(completion)
    }
    static func replace(_ saved: SavedAuthentication?, portal: String, namespace: UUID? = nil, completion: @escaping @Sendable (Bool) -> Void) {
        writes.append(Write(portal: portal, namespace: namespace, saved: saved, completion: completion))
    }
}

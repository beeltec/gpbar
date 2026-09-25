import Foundation

let helperServiceName = "com.beeltec.GPBar.helper"
let helperProtocolVersion = 11
let maximumMessageBytes = 256 * 1024

@objc protocol HelperProtocol {
    func configureLoginSSO(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func prepareForUpdate(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func inspect(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func send(_ command: Data, reply: @escaping @Sendable (Data) -> Void)
}

struct HelperRequest: Codable, Sendable {
    let protocolVersion: Int
    let commandID: UUID
}

struct HelperReply: Codable, Sendable {
    let protocolVersion: Int
    let commandID: UUID
    let runningAsRoot: Bool
    let authorizedUser: Bool
    let engineSessionsAvailable: Bool
    let activeSessionID: String?
    let sessionBusy: Bool
    let recoveryRequired: Bool
    let pendingAuthenticationUpdates: [AuthenticationCacheUpdate]
    let pendingKerberosPolicies: [KerberosPolicyUpdate]
    let loginSSO: LoginSSOState?
    var diagnostics: HelperDiagnosticSnapshot? = nil
}

extension HelperReply {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        commandID = try values.decode(UUID.self, forKey: .commandID)
        runningAsRoot = try values.decode(Bool.self, forKey: .runningAsRoot)
        authorizedUser = try values.decode(Bool.self, forKey: .authorizedUser)
        engineSessionsAvailable = try values.decode(Bool.self, forKey: .engineSessionsAvailable)
        activeSessionID = try values.decodeIfPresent(String.self, forKey: .activeSessionID)
        sessionBusy = try values.decode(Bool.self, forKey: .sessionBusy)
        recoveryRequired = try values.decode(Bool.self, forKey: .recoveryRequired)
        pendingAuthenticationUpdates = try values.decode([AuthenticationCacheUpdate].self, forKey: .pendingAuthenticationUpdates)
        pendingKerberosPolicies = try values.decode([KerberosPolicyUpdate].self, forKey: .pendingKerberosPolicies)
        loginSSO = try values.decodeIfPresent(LoginSSOState.self, forKey: .loginSSO)
        let snapshot = try? values.decodeIfPresent(HelperDiagnosticSnapshot.self, forKey: .diagnostics)
        diagnostics = snapshot?.isValid == true ? snapshot : nil
    }
}

struct AuthenticationCacheUpdate: Codable, Sendable, Equatable {
    let portal: String
    let revision: UUID
}

struct KerberosPolicyUpdate: Codable, Sendable, Equatable {
    let portal: String
    let revision: UUID
    let fallbackUntil: UInt64
}

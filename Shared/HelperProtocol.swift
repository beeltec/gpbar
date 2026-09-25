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

import Foundation

let helperServiceName = "com.beeltec.GPBar.helper"
let helperProtocolVersion = 6
let maximumMessageBytes = 256 * 1024

@objc protocol HelperProtocol {
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
}

struct AuthenticationCacheUpdate: Codable, Sendable, Equatable {
    let portal: String
    let revision: UUID
}

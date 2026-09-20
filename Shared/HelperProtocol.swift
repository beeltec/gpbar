import Foundation

let helperServiceName = "com.beelte.gpclient.helper"
let helperProtocolVersion = 1
let maximumMessageBytes = 256 * 1024

@objc protocol HelperProtocol {
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
}

import Foundation

struct EngineCommandEnvelope: Codable, Sendable {
    let protocolVersion: Int
    let sessionID: String
    let commandID: String
    let command: EngineCommand

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", sessionID = "session_id", commandID = "command_id", command
    }
}

struct EngineCommand: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case start, submitCallback = "submit_callback", submitOtp = "submit_otp", cancel, disconnect, getSnapshot = "get_snapshot"
        case recoverNetwork = "recover_network"
    }
    let type: Kind
    var portal: String?
    var reconnect: Bool?
    var challengeID: String?
    var callback: String?
    var otp: String?

    enum CodingKeys: String, CodingKey {
        case type, portal, reconnect, challengeID = "challenge_id", callback, otp
    }
}

struct EngineEventEnvelope: Codable, Sendable {
    let protocolVersion: Int
    let sessionID: String
    let sequence: UInt64
    let event: EngineEvent

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", sessionID = "session_id", sequence, event
    }
}

struct EngineEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ready, phaseChanged = "phase_changed", authenticationRequired = "authentication_required"
        case authenticationCompleted = "authentication_completed", otpRequired = "otp_required", snapshot, failure, stopped
    }
    let type: Kind
    var openconnectVersion: String?
    var phase: ConnectionPhase?
    var attempt: Int?
    var challengeID: String?
    var launchURL: String?
    var message: String?
    var snapshot: ConnectionSnapshot?
    var code: String?
    var retryable: Bool?
    var cleanup: String?

    enum CodingKeys: String, CodingKey {
        case type, openconnectVersion = "openconnect_version", phase, attempt, challengeID = "challenge_id"
        case launchURL = "launch_url", message, snapshot, code, retryable, cleanup
    }
}

enum ConnectionPhase: String, Codable, Sendable {
    case disconnected, preparing, authenticating, connecting, connected, reconnecting, disconnecting, failed, unknown
    var isActive: Bool { ![.disconnected, .failed].contains(self) }
}

struct ConnectionSnapshot: Codable, Sendable {
    var phase: ConnectionPhase
    var portal: String
    var gateway: String?
    var account: String?
    var interface: String?
    var ipv4: String?
    var startedAtUnix: UInt64?
    var attempt: Int

    enum CodingKeys: String, CodingKey {
        case phase, portal, gateway, account, interface, ipv4, startedAtUnix = "started_at_unix", attempt
    }
}

struct CommandReply: Codable, Sendable {
    let accepted: Bool
    let code: String?
}

@objc protocol AppEventProtocol {
    func receive(_ data: Data)
}

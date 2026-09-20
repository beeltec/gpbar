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
        case submitCredentials = "submit_credentials"
        case submitSignature = "submit_signature"
    }
    let type: Kind
    var portal: String?
    var reconnect: Bool?
    var challengeID: String?
    var callback: String?
    var otp: String?
    var username: String?
    var password: String?
    var identity: CertificateIdentity?
    var certificateOnly: Bool?
    var certificateUsername: String?
    var requestID: String?
    var signature: Data?
    var rememberAuthentication: Bool?
    var savedAuthentication: SavedAuthentication?

    enum CodingKeys: String, CodingKey {
        case type, portal, reconnect, challengeID = "challenge_id", callback, otp, username, password
        case identity, certificateOnly = "certificate_only", certificateUsername = "certificate_username"
        case requestID = "request_id", signature
        case rememberAuthentication = "remember_authentication", savedAuthentication = "saved_authentication"
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
        case credentialsRequired = "credentials_required"
        case signatureRequired = "signature_required"
        case authenticationCacheChanged = "authentication_cache_changed"
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
    var server: String?
    var usernameLabel: String?
    var passwordLabel: String?
    var requestID: String?
    var scheme: UInt16?
    var digest: Bool?
    var input: Data?
    var savedAuthentication: SavedAuthentication?

    enum CodingKeys: String, CodingKey {
        case type, openconnectVersion = "openconnect_version", phase, attempt, challengeID = "challenge_id"
        case launchURL = "launch_url", message, snapshot, code, retryable, cleanup
        case server, usernameLabel = "username_label", passwordLabel = "password_label"
        case requestID = "request_id", scheme, digest, input
        case savedAuthentication = "saved_authentication"
    }
}

struct CertificateIdentity: Codable, Sendable {
    let certificates: [Data]
    let schemes: [UInt16]

    var isValid: Bool {
        !certificates.isEmpty && certificates.count <= 16
            && certificates.allSatisfy { !$0.isEmpty && $0.count <= 16384 }
            && certificates.reduce(0, { $0 + $1.count }) <= 65536
            && !schemes.isEmpty && schemes.count <= 9
            && schemes.allSatisfy { [0x0401, 0x0501, 0x0601, 0x0804, 0x0805, 0x0806, 0x0403, 0x0503, 0x0603].contains($0) }
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

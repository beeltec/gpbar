import Foundation

enum HelperDiagnosticEventKind: String, Codable, Sendable {
    case processStarted, startupFailed, connectionAccepted, accessRejected
    case engineStartRequested, engineStarted, engineStartFailed, engineProtocolFailed, engineStartupTimedOut
    case cleanupCompleted, recoveryCompleted, recoveryFailed, loginCaptureAccepted
}

enum HelperDiagnosticReason: String, Codable, Sendable {
    case invalidRuntime, signingIdentityUnavailable, inactiveUser, invalidRequest
    case engineStartFailed, invalidEngineFrame, engineStartupTimedOut
    case restored, notNeeded, unverified, recoveryFailed
}

struct HelperDiagnosticEvent: Codable, Sendable {
    let sequence: UInt64
    let time: Date
    let kind: HelperDiagnosticEventKind
    let reason: HelperDiagnosticReason?
}

struct HelperDiagnosticSnapshot: Codable, Sendable {
    let formatVersion: Int
    let processStarted: Date
    let version: String?
    let build: String?
    let executablePath: String?
    let events: [HelperDiagnosticEvent]

    var isValid: Bool {
        guard formatVersion == 1, events.count <= 100,
              version.map({ Self.validVersion($0) }) != false,
              build.map({ Self.validBuild($0) }) != false,
              executablePath.map({ $0.utf8.count <= 2048 && $0.hasPrefix("/") && !$0.contains("\n") }) != false,
              Self.validTime(processStarted) else { return false }
        var sequence: UInt64 = 0
        for event in events {
            guard event.sequence > sequence else { return false }
            sequence = event.sequence
            guard Self.validTime(event.time) else { return false }
        }
        return true
    }

    private static func validTime(_ time: Date) -> Bool {
        let seconds = time.timeIntervalSince1970
        return seconds.isFinite && seconds >= 0 && seconds <= 4_102_444_800
    }

    static func validVersion(_ value: String) -> Bool {
        value.utf8.count <= 32 && value.split(separator: ".", omittingEmptySubsequences: false).count <= 4
            && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.allSatisfy({ $0 >= "0" && $0 <= "9" })
            }
    }

    static func validBuild(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}

struct HelperInspectionEnvelope: Codable {
    let protocolVersion: Int
    let commandID: UUID
}

import Foundation
import OSLog
import Darwin
import CoreFoundation

final class DiagnosticRecorder: @unchecked Sendable {
    static let shared = DiagnosticRecorder()

    private struct Record {
        let userID: uid_t?
        let event: HelperDiagnosticEvent
    }

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.beeltec.GPBar.helper", category: "lifecycle")
    private let started = Date()
    private let executable = DiagnosticRecorder.runningExecutable()
    private var records: [Record] = []
    private var nextSequence: UInt64 = 1

    private init() {}

    private static func runningExecutable() -> (version: String?, build: String?, path: String?) {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0, size <= 2048 else { return (nil, nil, nil) }
        var bytes = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&bytes, &size) == 0 else { return (nil, nil, nil) }
        let pathBytes = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: pathBytes, encoding: .utf8) else { return (nil, nil, nil) }
        let url = URL(fileURLWithPath: path)
        let info = CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any]
        return (info?["CFBundleShortVersionString"] as? String,
            info?["CFBundleVersion"] as? String, url.path)
    }

    func record(_ kind: HelperDiagnosticEventKind, reason: HelperDiagnosticReason? = nil, userID: uid_t? = nil) {
        lock.withLock {
            let entry = Record(userID: userID, event: HelperDiagnosticEvent(sequence: nextSequence,
                time: Date(), kind: kind, reason: reason))
            if nextSequence < UInt64.max { nextSequence += 1 }
            records.append(entry)
            if records.count > 100 { records.removeFirst(records.count - 100) }
        }
        let label = kind.rawValue
        let reasonLabel = reason?.rawValue ?? "none"
        switch kind {
        case .startupFailed, .accessRejected, .engineStartFailed, .engineProtocolFailed,
             .engineStartupTimedOut, .recoveryFailed:
            logger.error("\(label, privacy: .public): \(reasonLabel, privacy: .public)")
        default:
            logger.notice("\(label, privacy: .public): \(reasonLabel, privacy: .public)")
        }
    }

    func snapshot(for userID: uid_t) -> HelperDiagnosticSnapshot {
        let events = lock.withLock {
            records.filter { $0.userID == nil || $0.userID == userID }.map(\.event)
        }
        return HelperDiagnosticSnapshot(formatVersion: 1, processStarted: started,
            version: executable.version.flatMap { HelperDiagnosticSnapshot.validVersion($0) ? $0 : nil },
            build: executable.build.flatMap { HelperDiagnosticSnapshot.validBuild($0) ? $0 : nil },
            executablePath: executable.path, events: events)
    }
}

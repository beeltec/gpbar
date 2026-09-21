import Foundation
import Security
import Darwin

enum SecureRuntime {
    static let directory = URL(fileURLWithPath: "/Library/Application Support/GPBar", isDirectory: true)

    static func hasPendingSessions() throws -> Bool {
        let sessions = directory.appendingPathComponent("Sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessions.path) else { return false }
        try ensurePrivateDirectory(directory)
        try ensurePrivateDirectory(sessions)
        return try !FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil).isEmpty
    }

    static func recoverInactiveSessions() throws {
        try ensurePrivateDirectory(directory)
        let sessions = directory.appendingPathComponent("Sessions", isDirectory: true)
        try ensurePrivateDirectory(sessions)
        try recoverPreviousSessions(in: sessions)
    }

    static func prepare(sessionID: String) throws -> URL {
        try ensurePrivateDirectory(directory)
        let staging = directory.appendingPathComponent("Staging", isDirectory: true)
        try ensurePrivateDirectory(staging)
        for entry in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { throw RuntimeError.invalidBundle }
            try ensurePrivateDirectory(entry)
            try FileManager.default.removeItem(at: entry)
        }
        let sessions = directory.appendingPathComponent("Sessions", isDirectory: true)
        try ensurePrivateDirectory(sessions)
        try recoverPreviousSessions(in: sessions)
        let session = staging.appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = session.appendingPathComponent("GPBar.app", isDirectory: true)
        do {
            guard let executable = Bundle.main.executableURL else { throw RuntimeError.invalidBundle }
            let source = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard source.pathExtension == "app" else { throw RuntimeError.invalidBundle }
            try FileManager.default.copyItem(at: source, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw RuntimeError.invalidBundle }
            try verify(destination, identifier: "com.beeltec.GPBar")
            let contents = destination.appendingPathComponent("Contents", isDirectory: true)
            let engine = contents.appendingPathComponent("MacOS/openprotect")
            try verify(engine, identifier: "com.beeltec.GPBar.engine")
            guard let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw RuntimeError.invalidBundle
            }
            for case let entry as URL in enumerator {
                if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    let framework = contents.appendingPathComponent("Frameworks/Sparkle.framework").path + "/"
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
                    let resolved = entry.resolvingSymlinksInPath().path
                    guard entry.path.hasPrefix(framework), !target.hasPrefix("/"),
                          resolved.hasPrefix(framework), FileManager.default.fileExists(atPath: resolved) else {
                        throw RuntimeError.invalidBundle
                    }
                }
            }
            let final = sessions.appendingPathComponent(sessionID, isDirectory: true)
            try FileManager.default.moveItem(at: session, to: final)
            return final.appendingPathComponent("GPBar.app/Contents/MacOS/openprotect")
        } catch {
            try? FileManager.default.removeItem(at: session)
            throw error
        }
    }

    static func cancelNetworkWork(engine: URL) throws {
        try Data().write(to: sessionDirectory(engine).appendingPathComponent("cancelled"), options: .atomic)
    }

    static func engineIsRunning(in session: URL) -> Bool {
        guard let data = try? Data(contentsOf: session.appendingPathComponent("engine.json")), data.count < 16384,
              let recorded = try? JSONDecoder().decode(ProcessIdentity.self, from: data),
              let current = try? processIdentity(recorded.pid) else { return false }
        return current == recorded
    }

    static func recordProcess(_ pid: pid_t, engine: URL) throws {
        let session = sessionDirectory(engine)
        let identity = try processIdentity(pid)
        try JSONEncoder().encode(identity).write(to: session.appendingPathComponent("engine.json"), options: .atomic)
    }

    static func recover(engine: URL) throws {
        let helper = engine.deletingLastPathComponent().appendingPathComponent("GPBarHelper")
        try verify(helper, identifier: helperServiceName)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--network-recover"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { throw RuntimeError.recoveryRequired }
    }

    private static func recoverPreviousSessions(in sessions: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)
        for session in entries {
            guard UUID(uuidString: session.lastPathComponent) != nil else { throw RuntimeError.recoveryRequired }
            try ensurePrivateDirectory(session)
            let pidFile = session.appendingPathComponent("engine.json")
            if FileManager.default.fileExists(atPath: pidFile.path) {
                let data = try Data(contentsOf: pidFile)
                guard data.count < 16384 else { throw RuntimeError.recoveryRequired }
                let identity = try JSONDecoder().decode(ProcessIdentity.self, from: data)
                guard identity.pid > 1 else { throw RuntimeError.recoveryRequired }
                if kill(identity.pid, 0) == 0 {
                    if try processIdentity(identity.pid) == identity { throw RuntimeError.recoveryRequired }
                } else if errno != ESRCH { throw RuntimeError.recoveryRequired }
            }
            let bundle = session.appendingPathComponent("GPBar.app")
            try verify(bundle, identifier: "com.beeltec.GPBar")
            let engine = bundle.appendingPathComponent("Contents/MacOS/openprotect")
            try recover(engine: engine)
            try removeUnusedSession(engine: engine)
        }
    }

    private struct ProcessIdentity: Codable, Equatable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64
        let bootID: String
    }

    private static func processIdentity(_ pid: pid_t) throws -> ProcessIdentity {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw RuntimeError.recoveryRequired }
        var bytes = [UInt8](repeating: 0, count: 128)
        var length = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0,
              let bootID = String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8),
              UUID(uuidString: bootID) != nil else { throw RuntimeError.recoveryRequired }
        return ProcessIdentity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec, bootID: bootID)
    }

    private static func sessionDirectory(_ engine: URL) -> URL {
        engine.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func removeUnusedSession(engine: URL) throws {
        let session = sessionDirectory(engine)
        let sessions = directory.appendingPathComponent("Sessions", isDirectory: true)
        guard session.deletingLastPathComponent() == sessions else { throw RuntimeError.invalidBundle }
        try FileManager.default.removeItem(at: session)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? Int == 0,
              let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0 else {
            throw RuntimeError.invalidBundle
        }
    }

    private static func verify(_ url: URL, identifier: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = try SigningIdentity.requirement(for: identifier)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw RuntimeError.invalidBundle
        }
    }

    enum RuntimeError: Error { case invalidBundle, recoveryRequired }
}

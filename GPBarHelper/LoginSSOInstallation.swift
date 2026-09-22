import Foundation
import Security
import Darwin

enum LoginSSOInstallation {
    static let directory = SecureRuntime.directory.appendingPathComponent("LoginSSO", isDirectory: true)
    static let plugin = URL(fileURLWithPath: "/Library/Security/SecurityAgentPlugins/GPBarLogin.bundle", isDirectory: true)
    private static let right = "system.login.console"
    enum Failure: Error { case invalidInstallation, authorizationDenied, changedRule }

    static func state(userID: uid_t) throws -> LoginSSOState {
        let rule = try readRule()
        let installed = (rule["mechanisms"] as? [String])?.contains(loginSSOMechanism) == true
        return LoginSSOState(installed: installed, portal: try users()[String(userID)])
    }

    static func users() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        try SecureRuntime.ensurePrivateDirectory(directory)
        let file = directory.appendingPathComponent("users.plist")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? Int == 0,
              let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0,
              let size = attributes[.size] as? Int, size <= 65536 else { throw Failure.invalidInstallation }
        let result = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: file))
        guard result.count <= 64, result.allSatisfy({ UInt32($0.key).map { $0 >= 501 } == true && PortalAddress.normalize($0.value) == $0.value }) else {
            throw Failure.invalidInstallation
        }
        return result
    }

    static func configure(userID: uid_t, portal: String?, authorization: Data) throws {
        guard geteuid() == 0, userID >= 501,
              portal.map({ PortalAddress.normalize($0) == $0 }) != false else { throw Failure.invalidInstallation }
        let auth = try authorized(authorization)
        defer { AuthorizationFree(auth, []) }
        try SecureRuntime.ensurePrivateDirectory(SecureRuntime.directory)
        try SecureRuntime.ensurePrivateDirectory(directory)
        var allowed = try users()
        let original = try readRule()
        guard let mechanisms = original["mechanisms"] as? [String] else { throw Failure.invalidInstallation }
        if let portal {
            guard allowed.count < 64 || allowed[String(userID)] != nil else { throw Failure.invalidInstallation }
            let replacement = try LoginSSORule.mechanisms(mechanisms, installing: true)
            if !mechanisms.contains(loginSSOMechanism) {
                // Keep recovery evidence before changing the login rule.
                let backup = directory.appendingPathComponent("login-rule-before.plist")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: backup, options: .atomic)
                }
                try installPlugin()
                try replaceRule(original, mechanisms: replacement, authorization: auth)
            } else {
                guard replacement == mechanisms else { throw Failure.invalidInstallation }
                try verifyInstalledPlugin()
            }
            allowed[String(userID)] = portal
            try writeUsers(allowed)
        } else {
            allowed.removeValue(forKey: String(userID))
            // Stop capture before removing its authorization mechanism.
            try writeUsers(allowed)
            if allowed.isEmpty {
                let replacement = try LoginSSORule.mechanisms(mechanisms, installing: false)
                if replacement != mechanisms { try replaceRule(original, mechanisms: replacement, authorization: auth) }
                // Keep the inert bundle for hosts that still have the old rule loaded.
            }
        }
    }

    private static func writeUsers(_ users: [String: String]) throws {
        let file = directory.appendingPathComponent("users.plist")
        try PropertyListEncoder().encode(users).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func removeForRecovery() throws {
        guard geteuid() == 0 else { throw Failure.authorizationDenied }
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else {
            throw Failure.authorizationDenied
        }
        defer { AuthorizationFree(authorization, []) }
        let original = try readRule()
        guard let mechanisms = original["mechanisms"] as? [String] else { throw Failure.invalidInstallation }
        if FileManager.default.fileExists(atPath: directory.path) {
            try SecureRuntime.ensurePrivateDirectory(directory)
            try writeUsers([:])
        }
        let replacement = try LoginSSORule.mechanisms(mechanisms, installing: false)
        if replacement != mechanisms { try replaceRule(original, mechanisms: replacement, authorization: authorization) }
    }

    private static func authorized(_ data: Data) throws -> AuthorizationRef {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { throw Failure.authorizationDenied }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess, let reference else {
            throw Failure.authorizationDenied
        }
        let status = "system.privilege.admin".withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, [], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(reference, [])
            throw Failure.authorizationDenied
        }
        return reference
    }

    private static func readRule() throws -> [String: Any] {
        var rule: CFDictionary?
        guard AuthorizationRightGet(right, &rule) == errAuthorizationSuccess,
              let result = rule as? [String: Any], result["class"] as? String == "evaluate-mechanisms" else {
            throw Failure.invalidInstallation
        }
        return result
    }

    private static func replaceRule(_ original: [String: Any], mechanisms: [String], authorization: AuthorizationRef) throws {
        guard NSDictionary(dictionary: try readRule()).isEqual(to: original) else { throw Failure.changedRule }
        var replacement = original
        replacement["mechanisms"] = mechanisms
        guard AuthorizationRightSet(authorization, right, replacement as CFDictionary, nil, nil, nil) == errAuthorizationSuccess,
              (try readRule())["mechanisms"] as? [String] == mechanisms else { throw Failure.changedRule }
    }

    private static func verifyInstalledPlugin() throws {
        try validateTree(plugin)
        try SecureRuntime.verify(plugin, identifier: loginSSOPluginIdentifier)
    }

    private static func installPlugin() throws {
        let parent = plugin.deletingLastPathComponent()
        for path in ["/Library", "/Library/Security", parent.path] {
            if !FileManager.default.fileExists(atPath: path) {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755])
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  attributes[.ownerAccountID] as? Int == 0,
                  let mode = attributes[.posixPermissions] as? Int, mode & 0o022 == 0 else { throw Failure.invalidInstallation }
        }
        let replacing = FileManager.default.fileExists(atPath: plugin.path)
        if replacing { try verifyInstalledPlugin() }
        guard let executable = Bundle.main.executableURL else { throw Failure.invalidInstallation }
        let source = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PlugIns/GPBarLogin.bundle")
        let staging = directory.appendingPathComponent(UUID().uuidString + ".bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try validateTree(staging)
        try SecureRuntime.verify(staging, identifier: loginSSOPluginIdentifier)
        if replacing {
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, plugin.path, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure.invalidInstallation
            }
        } else {
            try FileManager.default.moveItem(at: staging, to: plugin)
        }
        try verifyInstalledPlugin()
    }

    private static func validateTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw Failure.invalidInstallation
        }
        var entries = [root]
        for case let entry as URL in enumerator { entries.append(entry) }
        for entry in entries {
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
            guard [.typeDirectory, .typeRegular].contains(attributes[.type] as? FileAttributeType),
                  attributes[.ownerAccountID] as? Int == 0,
                  let mode = attributes[.posixPermissions] as? Int, mode & 0o022 == 0 else { throw Failure.invalidInstallation }
        }
    }
}

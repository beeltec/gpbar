import Foundation

@main enum ProfileKeychainTests {
    enum Failure: Error { case check(String) }
    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure.check(name) }
    }
    static func replace(_ saved: SavedAuthentication?, portal: String, namespace: UUID?) async -> Bool {
        await withCheckedContinuation { continuation in
            KeychainAuthentication.replace(saved, portal: portal, namespace: namespace) { continuation.resume(returning: $0) }
        }
    }
    static func load(portal: String, namespace: UUID?) async throws -> SavedAuthentication? {
        try await withCheckedThrowingContinuation { continuation in
            KeychainAuthentication.load(portal: portal, namespace: namespace) { continuation.resume(with: $0) }
        }
    }
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { throw Failure.check("fixture path") }
        let path = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("keychain-ids")
        let ids = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
        guard ids.count == 3 else { throw Failure.check("fixture namespaces") }
        let portal = "https://profiles-\(ids[0].uuidString.lowercased()).invalid"
        if CommandLine.arguments.contains("--cleanup") {
            let namespaces: [UUID?] = [nil, ids[1], ids[2]]
            for namespace in namespaces {
                try expect(await replace(nil, portal: portal, namespace: namespace), "remove fixture cookie")
            }
            return
        }
        let now = UInt64(Date().timeIntervalSince1970)
        func record(_ username: String) -> SavedAuthentication {
            SavedAuthentication(portal: portal, username: username, computer: "profile-fixture",
                portalCookie: RetainedCookie(server: portal, username: username, value: "synthetic-profile-cookie",
                    issuedAt: now - 1, expiresAt: now + 300))
        }
        try expect(await replace(record("legacy-user"), portal: portal, namespace: nil), "save legacy fixture")
        try expect(await replace(record("first-user"), portal: portal, namespace: ids[1]), "save first profile")
        try expect(await replace(record("second-user"), portal: portal, namespace: ids[2]), "save second profile")
        try expect(try await load(portal: portal, namespace: nil)?.username == "legacy-user", "legacy namespace preserved")
        try expect(try await load(portal: portal, namespace: ids[1])?.username == "first-user", "first profile isolation")
        try expect(try await load(portal: portal, namespace: ids[2])?.username == "second-user", "second profile isolation")
        try expect(await replace(nil, portal: portal, namespace: ids[1]), "remove first profile cookie")
        try expect(try await load(portal: portal, namespace: ids[1]) == nil, "removed cookie unavailable")
        try expect(try await load(portal: portal, namespace: ids[2])?.username == "second-user", "deletion preserves other profile")
        try expect(try await load(portal: portal, namespace: nil)?.username == "legacy-user", "deletion preserves legacy cookie")
        print("PASS: 10 real Keychain profile namespace, legacy retention, and selective deletion checks")
    }
}

import CryptoKit
import Foundation
import LocalAuthentication
import Security

@main struct AuthenticationChecks {
    enum Failure: Error { case check(String) }
    struct SignRequest: Decodable {
        let scheme: UInt16
        let digest: Bool
        let input: Data
    }
    struct SignResponse: Encodable { let signature: Data? }

    static func expect(_ value: Bool, _ label: String) throws {
        if !value { throw Failure.check(label) }
    }

    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if CommandLine.arguments.last == "--cleanup-cookies" {
            let portal = try String(contentsOf: directory.appendingPathComponent("cookie-origin"), encoding: .utf8)
            try expect(await replace(nil, portal: portal), "remove synthetic cookie record")
            return
        }
        if CommandLine.arguments.count == 3 {
            try await identity(directory, name: CommandLine.arguments[2], serve: true)
            return
        }
        try models()
        try await storage(directory)
        for name in ["rsa", "p256", "p384", "p521"] {
            try await identity(directory, name: name, serve: false)
        }
        print("PASS: native certificate signatures, invalid requests, missing identities, cookie storage, scope, expiry, and Keychain interaction restoration")
    }

    static func replace(_ value: SavedAuthentication?, portal: String) async -> Bool {
        await withCheckedContinuation { continuation in
            KeychainAuthentication.replace(value, portal: portal) { continuation.resume(returning: $0) }
        }
    }

    static func load(_ portal: String) async throws -> SavedAuthentication? {
        try await withCheckedThrowingContinuation { continuation in
            KeychainAuthentication.load(portal: portal) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    static func storage(_ directory: URL) async throws {
        let portal = try String(contentsOf: directory.appendingPathComponent("cookie-origin"), encoding: .utf8)
        try expect(portal.hasPrefix("https://gpbar-fixture-") && portal.hasSuffix(".invalid"), "fixture-only cookie namespace")
        let now = UInt64(Date().timeIntervalSince1970)
        let record = SavedAuthentication(portal: portal, username: "fixture", computer: "fixture",
            portalCookie: RetainedCookie(server: portal, username: "fixture", value: "synthetic-cookie", issuedAt: now - 60, expiresAt: now + 3600))
        do {
            try expect(try await load(portal) == nil, "fixture starts without stored cookies")
            try expect(await replace(record, portal: portal), "save synthetic cookie with production Keychain code")
            try expect(try await load(portal)?.portalCookie?.value == "synthetic-cookie", "load saved cookie")
            try expect(try await load(portal + ":444") == nil, "cookie storage is origin-bound")
            try expect(!(await replace(record, portal: portal + ":444")), "reject cross-origin storage")
            for mutation in ["device", "version", "expiry", "malformed"] {
                try expect(await replace(record, portal: portal), "replace cookie with private ACL")
                try await corrupt(portal, mutation: mutation)
                try expect(try await load(portal) == nil, "reject \(mutation) record")
                try expect(try await load(portal) == nil, "invalid record remains removed")
            }
            try expect(await replace(record, portal: portal), "save before forgetting")
        } catch {
            _ = await replace(nil, portal: portal)
            throw error
        }
        try expect(await replace(nil, portal: portal), "forget saved sign-in")
        try expect(try await load(portal) == nil, "forgotten sign-in cannot be reused")
    }

    static func corrupt(_ portal: String, mutation: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UserKeychain.queue.async {
                continuation.resume(with: Result {
                    try UserKeychain.withoutInteraction {
                        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "com.beeltec.GPBar.authentication", kSecAttrAccount as String: portal,
                            kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: false]
                        var read = query
                        read[kSecReturnData as String] = true
                        var result: CFTypeRef?
                        try expect(SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess, "read only synthetic storage")
                        guard let data = result as? Data,
                              var stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw Failure.check("synthetic storage missing")
                        }
                        switch mutation {
                        case "device": stored["device"] = "different-device"
                        case "version": stored["version"] = 99
                        case "expiry":
                            guard var authentication = stored["authentication"] as? [String: Any],
                                  var cookie = authentication["portal_cookie"] as? [String: Any] else {
                                throw Failure.check("synthetic cookie missing")
                            }
                            cookie["expires_at"] = UInt64(Date().timeIntervalSince1970) - 1
                            authentication["portal_cookie"] = cookie
                            stored["authentication"] = authentication
                        default: break
                        }
                        let replacement = mutation == "malformed" ? Data("invalid".utf8) : try JSONSerialization.data(withJSONObject: stored)
                        try expect(SecItemUpdate(query as CFDictionary,
                            [kSecValueData as String: replacement] as CFDictionary) == errSecSuccess, "alter only synthetic storage")
                    }
                })
            }
        }
    }

    @MainActor static func identity(_ directory: URL, name: String, serve: Bool) async throws {
        var allowed: DarwinBoolean = false
        try expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess, "read signing interaction flag")
        try expect(SecKeychainSetUserInteractionAllowed(false) == errSecSuccess, "fixture signing must not prompt")
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        var keychain: SecKeychain?
        let path = directory.appendingPathComponent("\(UUID().uuidString).keychain").path
        let password = "fixture"
        let status = password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
        try expect(status == errSecSuccess, "create private fixture keychain")
        guard let keychain else { throw Failure.check("fixture keychain missing") }
        defer { SecKeychainDelete(keychain) }
        var searchList: CFArray?
        try expect(SecKeychainCopySearchList(&searchList) == errSecSuccess, "read search list")
        guard let searchList = searchList as? [SecKeychain] else { throw Failure.check("search list missing") }
        try expect(SecKeychainSetSearchList((searchList + [keychain]) as CFArray) == errSecSuccess, "append only fixture keychain")
        var trusted: SecTrustedApplication?
        var access: SecAccess?
        try expect(SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess, "fixture signing access")
        guard let trusted else { throw Failure.check("fixture signer missing") }
        try expect(SecAccessCreate("GPBar test identity" as CFString, [trusted] as CFArray, &access) == errSecSuccess, "fixture ACL")
        guard let access else { throw Failure.check("fixture ACL missing") }
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportExportKeychain as String: keychain,
            kSecImportExportAccess as String: access
        ]
        var imported: CFArray?
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).p12"))
        try expect(SecPKCS12Import(data as CFData, options as CFDictionary, &imported) == errSecSuccess, "import fixture identity")
        guard let items = imported as? [[String: Any]], let item = items.first,
              let value = item[kSecImportItemIdentity as String], CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw Failure.check("imported identity missing")
        }
        let identity = value as! SecIdentity
        var referenceValue: CFTypeRef?
        let query: [String: Any] = [kSecValueRef as String: identity, kSecReturnPersistentRef as String: true]
        try expect(SecItemCopyMatching(query as CFDictionary, &referenceValue) == errSecSuccess, "fixture persistent reference")
        guard let reference = referenceValue as? Data else { throw Failure.check("reference missing") }
        let context = KeychainContext()
        let descriptor = try await KeychainIdentity.load(reference: reference, context: context)
        try expect(descriptor.isValid, "valid production certificate descriptor")
        let certificateData = try Data(contentsOf: directory.appendingPathComponent("\(name).der"))
        try expect(descriptor.certificates.first == certificateData, "public chain matches selection")
        try expect(try await KeychainIdentity.tokenID(reference: reference) == nil, "software identity has no token identifier")
        if serve {
            try write(descriptor)
            while let line = readLine() {
                let request = try JSONDecoder().decode(SignRequest.self, from: Data(line.utf8))
                let signature = try? await KeychainIdentity.signature(reference: reference, context: context,
                    scheme: request.scheme, digest: request.digest, input: request.input)
                try write(SignResponse(signature: signature))
            }
            return
        }
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let key = SecCertificateCopyKey(certificate) else { throw Failure.check("public key missing") }
        let expected: [UInt16] = switch name {
        case "rsa": [0x0804, 0x0805, 0x0806, 0x0401, 0x0501, 0x0601]
        case "p256": [0x0403]
        case "p384": [0x0503]
        default: [0x0603]
        }
        try expect(descriptor.schemes == expected, "certificate signature schemes")
        let message = Data("synthetic TLS signing input".utf8)
        for scheme in expected {
            let algorithms = algorithms(scheme)
            for digest in [false, true] {
                let input = digest ? hash(message, scheme: scheme) : message
                let signature = try await KeychainIdentity.signature(reference: reference, context: context,
                    scheme: scheme, digest: digest, input: input)
                try expect(SecKeyVerifySignature(key, digest ? algorithms.1 : algorithms.0,
                    input as CFData, signature as CFData, nil), "verify delegated \(name) signature")
            }
        }
        if name == "p384" || name == "p521" {
            let input = Data(SHA256.hash(data: message))
            let signature = try await KeychainIdentity.signature(reference: reference, context: context,
                scheme: 0x0403, digest: true, input: input)
            try expect(SecKeyVerifySignature(key, .ecdsaSignatureDigestX962SHA256,
                input as CFData, signature as CFData, nil), "OpenConnect certificate matching digest")
        }
        for (scheme, digest, input) in [(UInt16(0x0201), false, message),
            (expected[0], false, Data()), (expected[0], false, Data(repeating: 1, count: 65537)),
            (expected[0], true, Data([1]))] {
            do {
                _ = try await KeychainIdentity.signature(reference: reference, context: context,
                    scheme: scheme, digest: digest, input: input)
                throw Failure.check("invalid signing request accepted")
            } catch KeychainIdentity.Failure.invalidRequest {}
        }
        context.invalidate()
        try expect(SecKeychainDelete(keychain) == errSecSuccess, "remove only fixture keychain")
        do {
            _ = try await KeychainIdentity.signature(reference: reference, context: KeychainContext(),
                scheme: expected[0], digest: false, input: message)
            throw Failure.check("removed identity accepted")
        } catch KeychainIdentity.Failure.unavailable {}
    }

    static func write<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    static func hash(_ input: Data, scheme: UInt16) -> Data {
        switch scheme {
        case 0x0401, 0x0403, 0x0804: Data(SHA256.hash(data: input))
        case 0x0501, 0x0503, 0x0805: Data(SHA384.hash(data: input))
        default: Data(SHA512.hash(data: input))
        }
    }

    static func algorithms(_ scheme: UInt16) -> (SecKeyAlgorithm, SecKeyAlgorithm) {
        switch scheme {
        case 0x0401: (.rsaSignatureMessagePKCS1v15SHA256, .rsaSignatureDigestPKCS1v15SHA256)
        case 0x0501: (.rsaSignatureMessagePKCS1v15SHA384, .rsaSignatureDigestPKCS1v15SHA384)
        case 0x0601: (.rsaSignatureMessagePKCS1v15SHA512, .rsaSignatureDigestPKCS1v15SHA512)
        case 0x0804: (.rsaSignatureMessagePSSSHA256, .rsaSignatureDigestPSSSHA256)
        case 0x0805: (.rsaSignatureMessagePSSSHA384, .rsaSignatureDigestPSSSHA384)
        case 0x0806: (.rsaSignatureMessagePSSSHA512, .rsaSignatureDigestPSSSHA512)
        case 0x0403: (.ecdsaSignatureMessageX962SHA256, .ecdsaSignatureDigestX962SHA256)
        case 0x0503: (.ecdsaSignatureMessageX962SHA384, .ecdsaSignatureDigestX962SHA384)
        default: (.ecdsaSignatureMessageX962SHA512, .ecdsaSignatureDigestX962SHA512)
        }
    }

    static func models() throws {
        let now = UInt64(Date().timeIntervalSince1970)
        let portal = "https://portal.example"
        func cookie(_ server: String = "https://portal.example", _ value: String = "fixture-cookie",
                    _ issued: UInt64? = nil, _ expires: UInt64? = nil) -> RetainedCookie {
            RetainedCookie(server: server, username: "alice", value: value,
                issuedAt: issued ?? (now - 60), expiresAt: expires ?? (now + 3600))
        }
        let current = cookie()
        let record = SavedAuthentication(portal: portal, username: "alice", computer: "fixture",
            portalCookie: current, gatewayCookie: cookie("https://gateway.example"))
        try expect(record.isValid && record.unexpired()?.gatewayCookie != nil, "separate portal and gateway cookies")
        let decoded = try JSONDecoder().decode(SavedAuthentication.self, from: JSONEncoder().encode(record))
        try expect(decoded.portalCookie?.value == current.value, "cookie IPC round trip")
        for invalid in [cookie("http://portal.example"), cookie("https://user@portal.example"),
            cookie(portal, ""), cookie(portal, "empty"), cookie(portal, "(null)"), cookie(portal, "a\nb"),
            cookie(portal, String(repeating: "a", count: 16385)), cookie(portal, "a", now, now),
            cookie(portal, "a", now, now + 366 * 86400)] {
            try expect(!invalid.isValid, "reject invalid saved cookie")
        }
        var expired = record
        expired.portalCookie = cookie(portal, "a", now - 120, now - 1)
        try expect(expired.unexpired()?.portalCookie == nil && expired.unexpired()?.gatewayCookie != nil, "prune only expired endpoint")
        expired.gatewayCookie = nil
        try expect(expired.unexpired() == nil, "fully expired record removed")
        expired.portalCookie = cookie(portal, "a", now + 60, now + 3600)
        try expect(expired.unexpired() == nil, "future cookie rejected")
        expired.portalCookie = cookie("https://other.example")
        try expect(!expired.isValid, "portal cookie origin bound")
        let wrongAccount = SavedAuthentication(portal: portal, username: "bob", computer: "fixture", portalCookie: current)
        try expect(!wrongAccount.isValid, "portal cookie account bound")
        let software = CertificateChoice(fingerprint: "fingerprint", name: "Fixture", reference: Data([1]), tokenID: nil)
        let card = CertificateChoice(fingerprint: "fingerprint", name: "Fixture", reference: Data([2]), tokenID: "card-one")
        let other = CertificateChoice(fingerprint: "fingerprint", name: "Fixture", reference: Data([3]), tokenID: "card-two")
        try expect(Set([software.id, card.id, other.id]).count == 3, "same certificate on different tokens stays distinct")
        var allowed: DarwinBoolean = false
        try expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess, "read interaction flag")
        let before = allowed.boolValue
        for fails in [false, true] {
            do {
                try UserKeychain.withoutInteraction {
                    var current: DarwinBoolean = true
                    try expect(SecKeychainGetUserInteractionAllowed(&current) == errSecSuccess && !current.boolValue, "suppress cookie prompts")
                    if fails { throw Failure.check("fixture failure") }
                }
            } catch Failure.check("fixture failure") {}
            try expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess && allowed.boolValue == before, "restore certificate prompts")
        }
    }
}

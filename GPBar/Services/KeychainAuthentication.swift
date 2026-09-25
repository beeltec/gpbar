import CryptoKit
import Darwin
import Foundation
import Security

enum KeychainAuthentication {
    private static let queue = UserKeychain.queue
    private static let service = "com.beeltec.GPBar.authentication"

    enum Failure: Error { case unavailable, invalidData }

    private struct Stored: Codable {
        let version: Int
        let device: String
        let authentication: SavedAuthentication
    }

    static func load(portal: String, namespace: UUID? = nil, completion: @escaping @Sendable (Result<SavedAuthentication?, Failure>) -> Void) {
        queue.async {
            do {
                let authentication: SavedAuthentication? = try UserKeychain.withoutInteraction {
                    var query = query(portal: portal, namespace: namespace)
                    query[kSecReturnData as String] = true
                    query[kSecMatchLimit as String] = kSecMatchLimitOne
                    var result: CFTypeRef?
                    let status = SecItemCopyMatching(query as CFDictionary, &result)
                    if status == errSecItemNotFound { return nil }
                    guard status == errSecSuccess, let data = result as? Data else { throw Failure.unavailable }
                    let stored = data.count <= 65536 ? try? JSONDecoder().decode(Stored.self, from: data) : nil
                    guard let stored, stored.version == 1, stored.device == (try device()),
                          stored.authentication.portal == portal, let authentication = stored.authentication.unexpired() else {
                        try remove(portal: portal, namespace: namespace)
                        return nil
                    }
                    return authentication
                }
                completion(.success(authentication))
            } catch { completion(.failure(.unavailable)) }
        }
    }

    static func replace(_ authentication: SavedAuthentication?, portal: String, namespace: UUID? = nil, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            do {
                try UserKeychain.withoutInteraction {
                    guard let authentication else {
                        try remove(portal: portal, namespace: namespace)
                        return
                    }
                    guard authentication.portal == portal, authentication.isValid,
                          let current = authentication.unexpired() else { throw Failure.invalidData }
                    let data = try JSONEncoder().encode(Stored(version: 1, device: try device(), authentication: current))
                    guard data.count <= 65536 else { throw Failure.invalidData }
                    let query = query(portal: portal, namespace: namespace)
                    var trusted: SecTrustedApplication?
                    var access: SecAccess?
                    guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess, let trusted,
                          SecAccessCreate("GPBar saved sign-in" as CFString, [trusted] as CFArray, &access) == errSecSuccess,
                          let access else { throw Failure.unavailable }
                    try remove(portal: portal, namespace: namespace)
                    var item = query
                    item[kSecValueData as String] = data
                    item[kSecAttrAccess as String] = access
                    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
                }
                completion(true)
            } catch { completion(false) }
        }
    }

    private static func query(portal: String, namespace: UUID?) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: namespace.map { "\($0.uuidString)|\(portal)" } ?? portal,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: false]
    }

    private static func remove(portal: String, namespace: UUID?) throws {
        let status = SecItemDelete(query(portal: portal, namespace: namespace) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
    }

    private static func device() throws -> String {
        var identifier = UUID().uuid
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&identifier, &timeout) == 0 else { throw Failure.unavailable }
        return SHA256.hash(data: Data(UUID(uuid: identifier).uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

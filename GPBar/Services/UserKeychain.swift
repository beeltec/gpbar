import Foundation
import Security

enum UserKeychain {
    static let queue = DispatchQueue(label: "com.beeltec.GPBar.keychain")
    enum Failure: Error { case unavailable }

    // The legacy interaction flag is process-wide. All owned Keychain operations use this queue.
    static func withoutInteraction<T>(_ operation: () throws -> T) throws -> T {
        var allowed: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw Failure.unavailable
        }
        let result = Result { try operation() }
        guard SecKeychainSetUserInteractionAllowed(allowed.boolValue) == errSecSuccess else {
            throw Failure.unavailable
        }
        return try result.get()
    }
}

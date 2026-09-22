import Foundation
import Security

// The reference is immutable and remains alive until the helper replies.
final class LoginSSOAuthorization: @unchecked Sendable {
    let data: Data
    private let reference: AuthorizationRef

    private init(reference: AuthorizationRef, data: Data) {
        self.reference = reference
        self.data = data
    }

    deinit { AuthorizationFree(reference, [.destroyRights]) }

    static func request() throws -> LoginSSOAuthorization {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
            throw HelperClient.HelperError.unavailable
        }
        do {
            let status = "system.privilege.admin".withCString { name in
                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { pointer in
                    var rights = AuthorizationRights(count: 1, items: pointer)
                    return AuthorizationCopyRights(reference, &rights, nil, [.interactionAllowed, .extendRights], nil)
                }
            }
            var external = AuthorizationExternalForm()
            guard status == errAuthorizationSuccess,
                  AuthorizationMakeExternalForm(reference, &external) == errAuthorizationSuccess else {
                throw HelperClient.HelperError.unavailable
            }
            return LoginSSOAuthorization(reference: reference, data: withUnsafeBytes(of: external) { Data($0) })
        } catch {
            AuthorizationFree(reference, [.destroyRights])
            throw error
        }
    }
}

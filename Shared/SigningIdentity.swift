import Foundation
import Security

enum SigningIdentity {
    static func requirement(for identifier: String) throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw IdentityError.unavailable
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw IdentityError.unavailable
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10,
              team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw IdentityError.unavailable
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    enum IdentityError: Error {
        case unavailable
    }
}

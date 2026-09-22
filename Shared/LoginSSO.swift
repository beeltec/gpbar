import Foundation
import Security

let loginSSOPluginIdentifier = "com.beeltec.GPBar.login-sso"
let loginSSOMechanism = "GPBarLogin:capture,privileged"
let loginSSOHostRequirement = "anchor apple and identifier \"com.apple.authorizationhosthelper.arm64\""

@objc(GPBarLoginCaptureProtocol) protocol LoginCaptureProtocol {
    func capture(_ username: String, password: String, userID: UInt32, reply: @escaping @Sendable () -> Void)
}

struct LoginSSORequest: Codable, Sendable {
    let protocolVersion: Int
    let portal: String?
    let authorization: Data
}

struct LoginSSOState: Codable, Sendable {
    let installed: Bool
    let portal: String?
}

enum LoginSSORule {
    enum Failure: Error { case unsupportedRule }

    static func isInstalled() throws -> Bool {
        var rule: CFDictionary?
        guard AuthorizationRightGet("system.login.console", &rule) == errAuthorizationSuccess,
              let dictionary = rule as? [String: Any], let mechanisms = dictionary["mechanisms"] as? [String] else {
            throw Failure.unsupportedRule
        }
        return mechanisms.contains(where: { $0.hasPrefix("GPBarLogin:") })
    }

    static func mechanisms(_ current: [String], installing: Bool) throws -> [String] {
        let remaining = current.filter { $0 != loginSSOMechanism }
        guard installing else { return remaining }
        guard remaining.filter({ $0 == "builtin:authenticate,privileged" }).count == 1,
              remaining.filter({ $0 == "builtin:login-success" }).count == 1,
              remaining.last == "loginwindow:done",
              let authentication = remaining.firstIndex(of: "builtin:authenticate,privileged"),
              let success = remaining.firstIndex(of: "builtin:login-success"),
              authentication < success,
              !remaining.contains(where: { $0.hasPrefix("GPBarLogin:") }) else {
            throw Failure.unsupportedRule
        }
        var result = remaining
        result.insert(loginSSOMechanism, at: success + 1)
        return result
    }
}

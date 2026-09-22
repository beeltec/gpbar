import Foundation
import Security

final class LoginCaptureService: NSObject, LoginCaptureProtocol {
    private let auditSessionID: UInt32

    init(auditSessionID: UInt32) { self.auditSessionID = auditSessionID }

    func capture(_ username: String, password: String, userID: UInt32, reply: @escaping @Sendable () -> Void) {
        guard username.utf8.count <= 1024, password.utf8.count <= 4096 else { reply(); return }
        let auditSessionID = auditSessionID
        Task {
            await SessionController.shared.captureLogin(username: username, password: password,
                                                        userID: userID, auditSessionID: auditSessionID)
            reply()
        }
    }
}

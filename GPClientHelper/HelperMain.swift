import Foundation
import SystemConfiguration

final class InspectionService: NSObject, HelperProtocol {
    private let userID: uid_t
    private let events: ClientEvents
    private let connectionID: UUID

    init(userID: uid_t, connection: NSXPCConnection, connectionID: UUID) {
        self.userID = userID
        self.events = ClientEvents(connection)
        self.connectionID = connectionID
    }

    func inspect(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= maximumMessageBytes,
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data),
              request.protocolVersion == helperProtocolVersion else {
            reply(Data())
            return
        }
        var consoleUser: uid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &consoleUser, nil)
        let authorized = name != nil && userID != 0 && consoleUser == userID
        let userID = userID
        let connectionID = connectionID
        let events = events
        Task {
            var activeSessionID: String?
            if authorized {
                activeSessionID = await SessionController.shared.attach(userID: userID, connectionID: connectionID) { data in
                    events.send(data)
                }
            }
            let response = HelperReply(protocolVersion: helperProtocolVersion, commandID: request.commandID,
                runningAsRoot: geteuid() == 0, authorizedUser: authorized, engineSessionsAvailable: true,
                activeSessionID: activeSessionID)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    func send(_ command: Data, reply: @escaping @Sendable (Data) -> Void) {
        let userID = userID
        Task {
            let result = await SessionController.shared.send(command, userID: userID)
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
}

// Configure XPC before resuming it. All later event sends use this lock.
private final class ClientEvents: @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()

    init(_ connection: NSXPCConnection) { self.connection = connection }

    func send(_ data: Data) {
        lock.withLock {
            let proxy = connection?.remoteObjectProxyWithErrorHandler { _ in }
            (proxy as? AppEventProtocol)?.receive(data)
        }
    }
}

final class HelperListener: NSObject, NSXPCListenerDelegate {
    let requirement: String

    init(requirement: String) {
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var consoleUser: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUser, nil) != nil,
              connection.effectiveUserIdentifier != 0,
              connection.effectiveUserIdentifier == consoleUser else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        let connectionID = UUID()
        connection.remoteObjectInterface = NSXPCInterface(with: AppEventProtocol.self)
        connection.exportedObject = InspectionService(userID: connection.effectiveUserIdentifier, connection: connection, connectionID: connectionID)
        connection.invalidationHandler = {
            Task { await SessionController.shared.detach(connectionID: connectionID) }
        }
        connection.resume()
        return true
    }
}

@main enum HelperMain {
    static func main() {
        if CommandLine.arguments.count == 2,
           ["--network-script", "--network-recover", "--network-verify"].contains(CommandLine.arguments[1]) {
            do { try NetworkSession().run(mode: CommandLine.arguments[1]); exit(EXIT_SUCCESS) }
            catch { exit(EXIT_FAILURE) }
        }
        guard CommandLine.arguments.count == 1 else { exit(EXIT_FAILURE) }
        guard geteuid() == 0,
              let requirement = try? SigningIdentity.requirement(for: "com.beelte.gpclient") else { exit(EXIT_FAILURE) }
        let delegate = HelperListener(requirement: requirement)
        let listener = NSXPCListener(machServiceName: helperServiceName)
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime(delegate) { RunLoop.current.run() }
    }
}

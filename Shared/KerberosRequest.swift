import Foundation

struct KerberosRequest: Sendable {
    let requestID: String
    let contextID: String
    let server: String
    let input: Data?

    init?(event: EngineEvent) {
        guard event.type == .kerberosRequired, let requestID = event.requestID, let contextID = event.contextID,
              Self.validID(requestID), Self.validID(contextID), let server = event.server,
              PortalAddress.normalize(server) == server, let host = URL(string: server)?.host,
              !host.contains(":"), host.contains(where: { $0.isLetter }),
              event.input.map({ !$0.isEmpty && $0.count <= 49152 }) != false else { return nil }
        self.requestID = requestID
        self.contextID = contextID
        self.server = server
        input = event.input
    }

    private static func validID(_ value: String) -> Bool {
        (16...64).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

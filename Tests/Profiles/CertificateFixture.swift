import Foundation

struct CertificateChoice: Identifiable {
    let id: String
    let name: String
    let reference: Data
    let tokenID: String?
}

final class KeychainContext: Sendable {
    func invalidate() {}
}

@MainActor enum KeychainIdentity {
    enum Failure: Error { case unavailable }
    static var metadata: [CheckedContinuation<String?, Error>] = []
    static func tokenID(reference: Data) async throws -> String? {
        try await withCheckedThrowingContinuation { metadata.append($0) }
    }
    static func loadChoices() async throws -> [CertificateChoice] { [] }
    static func load(reference: Data, context: KeychainContext) async throws -> CertificateIdentity { throw Failure.unavailable }
    static func signature(reference: Data, context: KeychainContext, scheme: UInt16, digest: Bool, input: Data) async throws -> Data {
        throw Failure.unavailable
    }
}

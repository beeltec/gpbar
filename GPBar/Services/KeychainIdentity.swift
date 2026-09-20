import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct CertificateChoice: Identifiable, Sendable {
    let fingerprint: String
    let name: String
    let reference: Data
    let tokenID: String?

    var id: String {
        guard let tokenID else { return fingerprint }
        return fingerprint + SHA256.hash(data: Data(tokenID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// Keychain work uses one serial queue. Only LAContext's pending-operation cancellation crosses that queue.
final class KeychainContext: @unchecked Sendable {
    fileprivate let value = LAContext()
    func invalidate() { value.invalidate() }
}

enum KeychainIdentity {
    private static let queue = DispatchQueue(label: "com.beeltec.GPBar.keychain")
    enum Failure: Error {
        case unavailable, unsupported, invalidRequest, accessDenied
    }

    static func loadChoices() async throws -> [CertificateChoice] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try choices() }) }
        }
    }

    static func load(reference: Data, context: KeychainContext) async throws -> CertificateIdentity {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try prepare(reference: reference, context: context.value) }) }
        }
    }

    static func signature(reference: Data, context: KeychainContext, scheme: UInt16, digest: Bool, input: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try sign(reference: reference, context: context.value, scheme: scheme, digest: digest, input: input) }) }
        }
    }

    static func choices() throws -> [CertificateChoice] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecMatchPolicy as String: SecPolicyCreateSSL(false, nil),
            kSecMatchTrustedOnly as String: false,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else { throw Failure.unavailable }
        var choices: [CertificateChoice] = []
        for identity in identities.prefix(128) {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  let publicKey = SecCertificateCopyKey(certificate), !schemes(for: publicKey).isEmpty else { continue }
            var reference: CFTypeRef?
            let referenceQuery: [String: Any] = [kSecValueRef as String: identity, kSecReturnPersistentRef as String: true]
            guard SecItemCopyMatching(referenceQuery as CFDictionary, &reference) == errSecSuccess,
                  let reference = reference as? Data, reference.count <= 4096 else { continue }
            let data = SecCertificateCopyData(certificate) as Data
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let key = try? privateKey(identity),
                  let attributes = SecKeyCopyAttributes(key) as? [String: Any] else { continue }
            let tokenID = attributes[kSecAttrTokenID as String] as? String
            let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Client certificate"
            let name = String(subject.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(256))
            let choice = CertificateChoice(fingerprint: fingerprint, name: name, reference: reference, tokenID: tokenID)
            if !choices.contains(where: { $0.id == choice.id }) { choices.append(choice) }
        }
        return choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func prepare(reference: Data, context: LAContext) throws -> CertificateIdentity {
        let identity = try resolve(reference: reference, context: context)
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw Failure.unavailable }
        let key = try privateKey(identity)
        let available = schemes(for: key).filter {
            guard let algorithm = algorithm(scheme: $0, digest: false) else { return false }
            return SecKeyIsAlgorithmSupported(key, .sign, algorithm)
        }
        guard !available.isEmpty else { throw Failure.unsupported }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { throw Failure.unavailable }
        SecTrustSetNetworkFetchAllowed(trust, false)
        // Build the public chain locally. The VPN server evaluates this client identity's trust.
        _ = SecTrustEvaluateWithError(trust, nil)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? [certificate]
        let certificates = chain.map { SecCertificateCopyData($0) as Data }
        guard !certificates.isEmpty, certificates.count <= 16,
              certificates.allSatisfy({ !$0.isEmpty && $0.count <= 16384 }),
              certificates.reduce(0, { $0 + $1.count }) <= 65536 else { throw Failure.unsupported }
        return CertificateIdentity(certificates: certificates, schemes: available)
    }

    static func sign(reference: Data, context: LAContext, scheme: UInt16, digest: Bool, input: Data) throws -> Data {
        guard !input.isEmpty, input.count <= 65536,
              let length = digestLength(scheme), !digest || input.count == length,
              let algorithm = algorithm(scheme: scheme, digest: digest) else { throw Failure.invalidRequest }
        let key = try privateKey(resolve(reference: reference, context: context))
        let available = schemes(for: key)
        let certificateMatch = digest && scheme == 0x0403 && available.contains { $0 & 0xff == 3 }
        guard (available.contains(scheme) || certificateMatch), SecKeyIsAlgorithmSupported(key, .sign, algorithm) else { throw Failure.unsupported }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, input as CFData, &error) else {
            _ = error?.takeRetainedValue()
            throw Failure.accessDenied
        }
        let result = signature as Data
        guard !result.isEmpty, result.count <= 1024 else { throw Failure.unsupported }
        return result
    }

    private static func resolve(reference: Data, context: LAContext) throws -> SecIdentity {
        guard !reference.isEmpty, reference.count <= 4096 else { throw Failure.invalidRequest }
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValuePersistentRef as String: reference,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result, CFGetTypeID(result) == SecIdentityGetTypeID() else { throw Failure.unavailable }
        return result as! SecIdentity
    }

    private static func privateKey(_ identity: SecIdentity) throws -> SecKey {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else { throw Failure.accessDenied }
        return key
    }

    private static func schemes(for key: SecKey) -> [UInt16] {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let type = attributes[kSecAttrKeyType as String] as? String,
              let bits = attributes[kSecAttrKeySizeInBits as String] as? Int else { return [] }
        if type == kSecAttrKeyTypeRSA as String, (2048...8192).contains(bits) {
            return [0x0804, 0x0805, 0x0806, 0x0401, 0x0501, 0x0601]
        }
        guard type == kSecAttrKeyTypeECSECPrimeRandom as String else { return [] }
        switch bits {
        case 256: return [0x0403]
        case 384: return [0x0503]
        case 521: return [0x0603]
        default: return []
        }
    }

    private static func digestLength(_ scheme: UInt16) -> Int? {
        switch scheme {
        case 0x0401, 0x0403, 0x0804: 32
        case 0x0501, 0x0503, 0x0805: 48
        case 0x0601, 0x0603, 0x0806: 64
        default: nil
        }
    }

    private static func algorithm(scheme: UInt16, digest: Bool) -> SecKeyAlgorithm? {
        switch (scheme, digest) {
        case (0x0401, false): .rsaSignatureMessagePKCS1v15SHA256
        case (0x0501, false): .rsaSignatureMessagePKCS1v15SHA384
        case (0x0601, false): .rsaSignatureMessagePKCS1v15SHA512
        case (0x0804, false): .rsaSignatureMessagePSSSHA256
        case (0x0805, false): .rsaSignatureMessagePSSSHA384
        case (0x0806, false): .rsaSignatureMessagePSSSHA512
        case (0x0403, false): .ecdsaSignatureMessageX962SHA256
        case (0x0503, false): .ecdsaSignatureMessageX962SHA384
        case (0x0603, false): .ecdsaSignatureMessageX962SHA512
        case (0x0401, true): .rsaSignatureDigestPKCS1v15SHA256
        case (0x0501, true): .rsaSignatureDigestPKCS1v15SHA384
        case (0x0601, true): .rsaSignatureDigestPKCS1v15SHA512
        case (0x0804, true): .rsaSignatureDigestPSSSHA256
        case (0x0805, true): .rsaSignatureDigestPSSSHA384
        case (0x0806, true): .rsaSignatureDigestPSSSHA512
        case (0x0403, true): .ecdsaSignatureDigestX962SHA256
        case (0x0503, true): .ecdsaSignatureDigestX962SHA384
        case (0x0603, true): .ecdsaSignatureDigestX962SHA512
        default: nil
        }
    }
}

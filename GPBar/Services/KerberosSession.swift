import Foundation
import GSS

actor KerberosSession {
    struct Reply: Sendable {
        let token: Data
        let complete: Bool
    }
    enum Failure: Error { case unavailable, invalidRequest, verificationFailed }
    private var context: gss_ctx_id_t?
    private var credential: gss_cred_id_t?
    private var target: gss_name_t?
    private var contextID: String?
    private var server: String?
    private var rounds = 0
    private let kerberosOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x02]
    private let spnegoOID: [UInt8] = [0x2b, 0x06, 0x01, 0x05, 0x05, 0x02]
    private let hostNameOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x12, 0x01, 0x02, 0x01, 0x04]
    // Swift cannot import the GSS_S_CONTINUE_NEEDED macro.
    private let continueNeeded: OM_uint32 = 1

    func step(_ request: KerberosRequest) throws -> Reply {
        try Task.checkCancellation()
        do {
            if request.input == nil {
                clear()
                try prepare(request)
            }
            guard contextID == request.contextID, server == request.server, rounds < 4,
                  let credential, let target else { throw Failure.invalidRequest }
            rounds += 1
            return try withOID(spnegoOID) { oid in
                var minor: OM_uint32 = 0
                var flags: OM_uint32 = 0
                var output = gss_buffer_desc(length: 0, value: nil)
                defer { gss_release_buffer(&minor, &output) }
                let major = (request.input ?? Data()).withUnsafeBytes { bytes in
                    var input = gss_buffer_desc(length: bytes.count, value: UnsafeMutableRawPointer(mutating: bytes.baseAddress))
                    return gss_init_sec_context(&minor, credential, &context, target, oid,
                        OM_uint32(GSS_C_MUTUAL_FLAG | GSS_C_REPLAY_FLAG | GSS_C_SEQUENCE_FLAG), 0, nil,
                        &input, nil, &output, &flags, nil)
                }
                guard major == GSS_S_COMPLETE || major == continueNeeded else {
                    throw Failure.verificationFailed
                }
                guard output.length <= 49152,
                      major != GSS_S_COMPLETE || flags & OM_uint32(GSS_C_MUTUAL_FLAG) != 0,
                      flags & OM_uint32(GSS_C_DELEG_FLAG) == 0 else { throw Failure.verificationFailed }
                try verifyTarget(request.server)
                try Task.checkCancellation()
                let token = output.value.map { Data(bytes: $0, count: output.length) } ?? Data()
                return Reply(token: token, complete: major == GSS_S_COMPLETE)
            }
        } catch {
            clear()
            throw error
        }
    }

    func finish(_ id: String? = nil) {
        if id == nil || id == contextID { clear() }
    }

    private func prepare(_ request: KerberosRequest) throws {
        guard geteuid() != 0, let host = URL(string: request.server)?.host else { throw Failure.invalidRequest }
        var minor: OM_uint32 = 0
        var mechanisms: gss_OID_set?
        guard gss_create_empty_oid_set(&minor, &mechanisms) == GSS_S_COMPLETE else { throw Failure.verificationFailed }
        defer { gss_release_oid_set(&minor, &mechanisms) }
        guard var set = mechanisms else { throw Failure.verificationFailed }
        let added = withOID(kerberosOID) { gss_add_oid_set_member(&minor, $0, &set) }
        mechanisms = set
        guard added == GSS_S_COMPLETE else { throw Failure.verificationFailed }
        let acquired = gss_acquire_cred(&minor, nil, 0, mechanisms, GSS_C_INITIATE | GSS_C_CRED_NO_UI,
            &credential, nil, nil)
        guard acquired == GSS_S_COMPLETE else {
            if acquired == GSS_S_NO_CRED || acquired == GSS_S_CREDENTIALS_EXPIRED { throw Failure.unavailable }
            throw Failure.verificationFailed
        }
        let name = Data("HTTP@\(host)".utf8)
        let status = name.withUnsafeBytes { bytes in
            var buffer = gss_buffer_desc(length: bytes.count, value: UnsafeMutableRawPointer(mutating: bytes.baseAddress))
            return withOID(hostNameOID) { gss_import_name(&minor, &buffer, $0, &target) }
        }
        guard status == GSS_S_COMPLETE else { throw Failure.verificationFailed }
        contextID = request.contextID
        server = request.server
    }

    private func verifyTarget(_ server: String) throws {
        guard let context, let host = URL(string: server)?.host else { throw Failure.invalidRequest }
        var minor: OM_uint32 = 0
        var name: gss_name_t?
        var mechanism: gss_OID?
        defer { if name != nil { gss_release_name(&minor, &name) } }
        guard gss_inquire_context(&minor, context, nil, &name, nil, &mechanism, nil, nil, nil) == GSS_S_COMPLETE,
              let name, let mechanism,
              withOID(kerberosOID, { gss_oid_equal(mechanism, $0) != 0 }) else { throw Failure.verificationFailed }
        var buffer = gss_buffer_desc(length: 0, value: nil)
        defer { gss_release_buffer(&minor, &buffer) }
        guard gss_display_name(&minor, name, &buffer, nil) == GSS_S_COMPLETE,
              buffer.length <= 4096, let bytes = buffer.value,
              let value = String(data: Data(bytes: bytes, count: buffer.length), encoding: .utf8),
              value.hasPrefix("HTTP/\(host)@"), value.count > host.count + 6 else { throw Failure.verificationFailed }
    }

    private func withOID<T>(_ bytes: [UInt8], _ action: (gss_OID) throws -> T) rethrows -> T {
        try bytes.withUnsafeBytes { buffer in
            var oid = gss_OID_desc(length: OM_uint32(buffer.count), elements: UnsafeMutableRawPointer(mutating: buffer.baseAddress))
            return try action(&oid)
        }
    }

    private func clear() {
        var minor: OM_uint32 = 0
        if context != nil { gss_delete_sec_context(&minor, &context, nil) }
        if credential != nil { gss_release_cred(&minor, &credential) }
        if target != nil { gss_release_name(&minor, &target) }
        contextID = nil
        server = nil
        rounds = 0
    }
}

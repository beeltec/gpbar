import Foundation

@main struct NativeChecks {
    enum Failure: Error { case check(String) }
    static func expect(_ value: Bool, _ label: String) throws {
        if !value { throw Failure.check(label) }
    }
    static func request(_ host: String, context: String, input: Data? = nil) throws -> KerberosRequest {
        let event = EngineEvent(type: .kerberosRequired, server: "https://\(host)",
            requestID: String(repeating: "a", count: 48), input: input, contextID: context)
        guard let result = KerberosRequest(event: event) else { throw Failure.check("valid request") }
        return result
    }
    static func main() async throws {
        let context = String(repeating: "b", count: 48)
        for server in ["http://localhost", "https://user@localhost", "https://localhost/path", "https://127.0.0.1", "https://[::1]"] {
            let event = EngineEvent(type: .kerberosRequired, server: server, requestID: context, contextID: context)
            try expect(KerberosRequest(event: event) == nil, "reject unsafe service name")
        }
        let native = KerberosSession()
        if CommandLine.arguments.contains("--missing") {
            do {
                _ = try await native.step(request("portal.gpbar.test", context: context))
                throw Failure.check("accepted missing tickets")
            } catch KerberosSession.Failure.unavailable {}
            await native.finish()
            print("PASS: missing tickets fail without password prompts")
            return
        }
        for host in ["portal.gpbar.test", "gateway.gpbar.test"] {
            let initial = try await native.step(request(host, context: context))
            try expect(!initial.complete && !initial.token.isEmpty, "Kerberos initial ticket")
            let acceptor = Process()
            acceptor.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let input = Pipe(), output = Pipe()
            acceptor.standardInput = input
            acceptor.standardOutput = output
            try acceptor.run()
            try input.fileHandleForWriting.write(contentsOf: initial.token)
            try input.fileHandleForWriting.close()
            let token = output.fileHandleForReading.readDataToEndOfFile()
            acceptor.waitUntilExit()
            try expect(acceptor.terminationStatus == 0 && !token.isEmpty, "MIT acceptor verified ticket")
            let final = try await native.step(request(host, context: context, input: token))
            try expect(final.complete && final.token.isEmpty, "mutual Kerberos completion")
            await native.finish(context)
            do {
                _ = try await native.step(request(host, context: context, input: token))
                throw Failure.check("accepted stale context")
            } catch is KerberosSession.Failure {}
        }
        _ = try await native.step(request("portal.gpbar.test", context: context))
        do {
            _ = try await native.step(request("gateway.gpbar.test", context: context, input: Data([1])))
            throw Failure.check("accepted changed service principal")
        } catch is KerberosSession.Failure {}
        _ = try await native.step(request("portal.gpbar.test", context: context))
        do {
            _ = try await native.step(request("portal.gpbar.test", context: context, input: Data([1, 2, 3])))
            throw Failure.check("accepted invalid server token")
        } catch KerberosSession.Failure.verificationFailed {}
        let cancelled = Task { try await native.step(request("portal.gpbar.test", context: context)) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure.check("accepted cancelled operation") }
        catch is CancellationError {}
        await native.finish()
        print("PASS: native Kerberos tickets, portal/gateway principals, mutual authentication, stale replies, cancellation, and input validation")
    }
}

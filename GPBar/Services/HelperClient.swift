import Foundation

@MainActor final class HelperClient: NSObject, AppEventProtocol {
    var onEvent: ((EngineEventEnvelope) -> Void)?
    var onInterruption: (() -> Void)?
    private var connection: NSXPCConnection?
    private var generation: UUID?
    private var pending: UUID?
    private var completion: ((Result<HelperReply, HelperError>) -> Void)?
    private var timeout: Task<Void, Never>?
    private var updatePreparation: CommandCompletion?

    enum HelperError: Error { case unavailable, invalidReply, signingIdentity }

    nonisolated func receive(_ data: Data) {
        guard data.count <= maximumMessageBytes,
              let event = try? JSONDecoder().decode(EngineEventEnvelope.self, from: data),
              event.protocolVersion == helperProtocolVersion else { return }
        Task { @MainActor in self.onEvent?(event) }
    }

    func inspect(completion: @escaping (Result<HelperReply, HelperError>) -> Void) {
        guard pending == nil else { return }
        let request = HelperRequest(protocolVersion: helperProtocolVersion, commandID: UUID())
        guard let data = try? JSONEncoder().encode(request) else {
            completion(.failure(.invalidReply)); return
        }
        do { try connectIfNeeded() }
        catch { completion(.failure(.signingIdentity)); return }
        pending = request.commandID
        self.completion = completion
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.finish(request.commandID, .failure(.unavailable))
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] _ in
            Task { @MainActor in self?.finish(request.commandID, .failure(.unavailable)) }
        }) as? HelperProtocol else { finish(request.commandID, .failure(.unavailable)); return }
        proxy.inspect(data) { [weak self] data in
            let response = data.count <= maximumMessageBytes ? try? JSONDecoder().decode(HelperReply.self, from: data) : nil
            Task { @MainActor in
                guard let response, response.protocolVersion == helperProtocolVersion,
                      response.commandID == request.commandID else {
                    self?.finish(request.commandID, .failure(.invalidReply)); return
                }
                self?.finish(request.commandID, .success(response))
            }
        }
    }

    func send(_ command: EngineCommandEnvelope, completion: @escaping (CommandReply) -> Void) {
        guard let bytes = try? JSONEncoder().encode(command), bytes.count < maximumMessageBytes,
              let connection else { completion(CommandReply(accepted: false, code: "helper_unavailable")); return }
        let result = CommandCompletion(completion)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            result.finish(CommandReply(accepted: false, code: "command_timeout"))
        }
        result.timeout = timeout
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
            Task { @MainActor in result.finish(CommandReply(accepted: false, code: "helper_unavailable")) }
        }) as? HelperProtocol else { result.finish(CommandReply(accepted: false, code: "helper_unavailable")); return }
        proxy.send(bytes) { data in
            let reply = data.count <= maximumMessageBytes ? try? JSONDecoder().decode(CommandReply.self, from: data) : nil
            Task { @MainActor in result.finish(reply ?? CommandReply(accepted: false, code: "invalid_reply")) }
        }
    }

    func prepareForUpdate() async -> Bool {
        guard let connection, let generation,
              let data = try? JSONEncoder().encode(HelperRequest(protocolVersion: helperProtocolVersion, commandID: UUID())) else { return false }
        return await withCheckedContinuation { continuation in
            let result = CommandCompletion { [weak self] reply in
                self?.updatePreparation = nil
                continuation.resume(returning: reply.accepted)
            }
            updatePreparation = result
            result.timeout = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                result.finish(CommandReply(accepted: false, code: "update_timeout"))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
                Task { @MainActor in result.finish(CommandReply(accepted: false, code: "helper_unavailable")) }
            }) as? HelperProtocol else { result.finish(CommandReply(accepted: false, code: "helper_unavailable")); return }
            proxy.prepareForUpdate(data) { data in
                let reply = data.count <= maximumMessageBytes ? try? JSONDecoder().decode(CommandReply.self, from: data) : nil
                Task { @MainActor [weak self] in
                    guard self?.generation == generation else {
                        result.finish(CommandReply(accepted: false, code: "helper_unavailable"))
                        return
                    }
                    result.finish(reply ?? CommandReply(accepted: false, code: "invalid_reply"))
                }
            }
        }
    }

    func configureLoginSSO(portal: String?, authorization: Data) async -> Bool {
        guard let connection, let generation,
              let data = try? JSONEncoder().encode(LoginSSORequest(protocolVersion: helperProtocolVersion,
                  portal: portal, authorization: authorization)) else { return false }
        return await withCheckedContinuation { continuation in
            let result = CommandCompletion { continuation.resume(returning: $0.accepted) }
            result.timeout = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                result.finish(CommandReply(accepted: false, code: "login_sso_timeout"))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable _ in
                Task { @MainActor in result.finish(CommandReply(accepted: false, code: "helper_unavailable")) }
            }) as? HelperProtocol else { result.finish(CommandReply(accepted: false, code: "helper_unavailable")); return }
            proxy.configureLoginSSO(data) { [weak self] data in
                let reply = data.count <= maximumMessageBytes ? try? JSONDecoder().decode(CommandReply.self, from: data) : nil
                Task { @MainActor in
                    result.finish(self?.generation == generation ? reply ?? CommandReply(accepted: false, code: "invalid_reply")
                                  : CommandReply(accepted: false, code: "helper_unavailable"))
                }
            }
        }
    }

    private func connectIfNeeded() throws {
        guard connection == nil else { return }
        let requirement = try SigningIdentity.requirement(for: helperServiceName)
        let connection = NSXPCConnection(machServiceName: helperServiceName, options: .privileged)
        let generation = UUID()
        self.generation = generation
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: AppEventProtocol.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.lostConnection(generation) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.lostConnection(generation) }
        }
        self.connection = connection
        connection.resume()
    }

    private func lostConnection(_ generation: UUID) {
        guard self.generation == generation else { return }
        cancel()
        onInterruption?()
    }

    func cancel() {
        generation = nil
        updatePreparation?.finish(CommandReply(accepted: false, code: "helper_unavailable"))
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.exportedObject = nil
        connection?.invalidate()
        connection = nil
        if let pending { finish(pending, .failure(.unavailable)) }
    }

    private func finish(_ commandID: UUID, _ result: Result<HelperReply, HelperError>) {
        guard pending == commandID else { return }
        let callback = completion
        pending = nil
        completion = nil
        timeout?.cancel()
        timeout = nil
        if case .failure = result { cancel() }
        callback?(result)
    }
}

@MainActor private final class CommandCompletion {
    var timeout: Task<Void, Never>?
    private var completion: ((CommandReply) -> Void)?

    init(_ completion: @escaping (CommandReply) -> Void) { self.completion = completion }

    func finish(_ reply: CommandReply) {
        let callback = completion
        completion = nil
        timeout?.cancel()
        timeout = nil
        callback?(reply)
    }
}

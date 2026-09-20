import Darwin
import Foundation
import SystemConfiguration

// This worker is invoked only from the verified, root-private session bundle.
final class NetworkSession {
    struct Route: Codable {
        let network: String
        let ipv6: Bool
        let interface: String
        let gateway: String?
        var applied = false
        var interfaceIndex: UInt32?
    }
    struct Value: Codable {
        let key: String
        let installed: Data
    }
    struct Journal: Codable {
        var version = 1
        var bootID: String?
        var ready = false
        var interface: String?
        var interfaceIndex: UInt32?
        var address: String?
        var address6: String?
        var routes: [Route] = []
        var values: [Value] = []
    }
    enum Failure: Error { case invalidSession, invalidConfiguration, conflict, command, verification, journal }
    private let directory: URL
    private let journalURL: URL
    private let store: SCDynamicStore
    private var journal: Journal
    private let lockFD: Int32
    private var configuring = false
    private var operation = "initialization"

    init() throws {
        guard geteuid() == 0, let executable = Bundle.main.executableURL else { throw Failure.invalidSession }
        directory = executable.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard directory.deletingLastPathComponent() == SecureRuntime.directory.appendingPathComponent("Sessions", isDirectory: true),
              UUID(uuidString: directory.lastPathComponent) != nil else { throw Failure.invalidSession }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? Int == 0,
              let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0 else { throw Failure.invalidSession }
        journalURL = directory.appendingPathComponent("network.json")
        guard let store = SCDynamicStoreCreate(nil, "GPBar" as CFString, nil, nil) else { throw Failure.command }
        self.store = store
        lockFD = open(directory.appendingPathComponent("network.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw Failure.journal }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); throw Failure.conflict }
        do {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                let data = try Data(contentsOf: journalURL)
                guard data.count < 2 * 1024 * 1024 else { throw Failure.journal }
                journal = try JSONDecoder().decode(Journal.self, from: data)
                guard journal.version == 1, journal.routes.count <= 2048, journal.values.count <= 3 else { throw Failure.journal }
            } else { journal = Journal() }
            let currentBoot = try Self.bootID()
            if let previousBoot = journal.bootID, previousBoot != currentBoot { journal = Journal() }
            journal.bootID = currentBoot
        } catch { close(lockFD); throw error }
    }

    deinit { close(lockFD) }

    func run(mode: String) throws {
        if mode == "--network-recover" { try cleanup(); return }
        if mode == "--network-verify" {
            guard journal.ready else {
                if let data = try? Data(contentsOf: directory.appendingPathComponent("failure.txt")), data.count <= 256 {
                    try? FileHandle.standardOutput.write(contentsOf: data)
                }
                throw Failure.verification
            }
            for route in journal.routes {
                guard try owns(route) else { throw Failure.verification }
            }
            for value in journal.values {
                guard try matches(value) else { throw Failure.verification }
            }
            return
        }
        let environment = ProcessInfo.processInfo.environment
        switch environment["reason"] {
        case "pre-init": break
        case "connect", "reconnect":
            try cleanup()
            do { try configure(environment) }
            catch {
                let kind = (error as? Failure).map { String(describing: $0) } ?? "unknown"
                try? Data("\(operation):\(kind)".utf8).write(to: directory.appendingPathComponent("failure.txt"), options: .atomic)
                try? cleanup()
                throw error
            }
        case "disconnect": try cleanup()
        case "attempt-reconnect": journal.ready = false; try save()
        default: throw Failure.invalidConfiguration
        }
    }

    private func configure(_ environment: [String: String]) throws {
        configuring = true
        operation = "configuration"
        defer { configuring = false }
        guard let device = environment["TUNDEV"], device.hasPrefix("utun"),
              !device.dropFirst(4).isEmpty, device.dropFirst(4).allSatisfy(\.isNumber), device.count < 16,
              if_nametoindex(device) != 0,
              let address = environment["INTERNAL_IP4_ADDRESS"], Self.ip(address, ipv6: false),
              let gateway = environment["VPNGATEWAY"], Self.ip(gateway, ipv6: gateway.contains(":")) else {
            throw Failure.invalidConfiguration
        }
        let mtu = Int(environment["INTERNAL_IP4_MTU"] ?? "1412") ?? 0
        guard (576...9000).contains(mtu) else { throw Failure.invalidConfiguration }
        let gateway6 = gateway.contains(":")
        let outside = try lookup(gateway + (gateway6 ? "/128" : "/32"), ipv6: gateway6)
        guard let outsideInterface = outside["interface"], !outsideInterface.hasPrefix("utun") else { throw Failure.conflict }
        let outsideGateway = try Self.routeGateway(outside, ipv6: gateway6)
        let current = try command("/sbin/ifconfig", [device])
        operation = "interface_preflight"
        let existingIPv6 = current.split(separator: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }) }
            .filter { $0.first == "inet6" }
        guard !current.contains("\n\tinet "), existingIPv6.allSatisfy({ fields in
            guard fields.count > 1 else { return false }
            let address = String(fields[1].split(separator: "%")[0])
            var bytes = [UInt8](repeating: 0, count: 16)
            return inet_pton(AF_INET6, address, &bytes) == 1 && bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
        }) else { throw Failure.conflict }
        journal.interface = device
        journal.interfaceIndex = if_nametoindex(device)
        journal.address = address
        try save()
        try command("/sbin/ifconfig", [device, "inet", address, address, "netmask", "255.255.255.255", "mtu", String(mtu), "up"])
        let gatewayRoute = Route(network: gateway + (gateway6 ? "/128" : "/32"), ipv6: gateway6,
                                 interface: outsideInterface, gateway: outsideGateway)
        // An existing host route remains owned by its original writer.
        if !Self.exact(outside, network: gatewayRoute.network, ipv6: gateway6) { try add(gatewayRoute) }
        for ipv6 in [false, true] {
            if ipv6 {
                guard let address6 = environment["INTERNAL_IP6_ADDRESS"], !address6.isEmpty else { continue }
                guard Self.ip(address6, ipv6: true) else { throw Failure.invalidConfiguration }
                journal.address6 = address6
                try save()
                try command("/sbin/ifconfig", [device, "inet6", address6, "prefixlen", "128", "mtu", String(mtu), "up"])
            }
            let prefix = ipv6 ? "CISCO_IPV6_SPLIT" : "CISCO_SPLIT"
            for kind in ["EXC", "INC"] {
                let key = "\(prefix)_\(kind)"
                let count = Int(environment[key] ?? (kind == "INC" ? "-1" : "0")) ?? -2
                guard (-1...1024).contains(count) else { throw Failure.invalidConfiguration }
                var networks: [String] = []
                if count == -1 && kind == "INC" {
                    networks = ipv6 ? ["::/1", "8000::/1"] : ["0.0.0.0/1", "128.0.0.0/1"]
                } else if count > 0 {
                    for index in 0..<count {
                        guard let ip = environment["\(key)_\(index)_ADDR"], Self.ip(ip, ipv6: ipv6),
                              let mask = environment["\(key)_\(index)_MASKLEN"], let bits = Int(mask),
                              (0...(ipv6 ? 128 : 32)).contains(bits) else { throw Failure.invalidConfiguration }
                        if bits == 0 {
                            networks += ipv6 ? ["::/1", "8000::/1"] : ["0.0.0.0/1", "128.0.0.0/1"]
                        } else { networks.append("\(ip)/\(bits)") }
                    }
                }
                for network in networks {
                    if kind == "INC" {
                        try add(Route(network: network, ipv6: ipv6, interface: device, gateway: nil))
                    } else {
                        let original = try lookup(network, ipv6: ipv6)
                        guard let interface = original["interface"], !interface.hasPrefix("utun") else { throw Failure.conflict }
                        let gateway = try Self.routeGateway(original, ipv6: ipv6)
                        if !Self.exact(original, network: network, ipv6: ipv6) {
                            try add(Route(network: network, ipv6: ipv6, interface: interface, gateway: gateway))
                        }
                    }
                }
            }
        }
        let servers = ((environment["INTERNAL_IP4_DNS"] ?? "") + " " + (environment["INTERNAL_IP6_DNS"] ?? ""))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard servers.count <= 16, servers.allSatisfy({ Self.ip($0, ipv6: $0.contains(":")) }) else { throw Failure.invalidConfiguration }
        if !servers.isEmpty {
            let domains = (environment["CISCO_SPLIT_DNS"] ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            guard domains.count <= 128, domains.allSatisfy(Self.domain) else { throw Failure.invalidConfiguration }
            let key = "State:/Network/Service/GPBar-\(directory.lastPathComponent)"
            var dns: [String: Any] = ["ServerAddresses": servers, "SupplementalMatchDomains": domains.isEmpty ? [""] : domains,
                                     "SupplementalMatchOrders": Array(repeating: 100000, count: max(1, domains.count)), "InterfaceName": device]
            if let domain = environment["CISCO_DEF_DOMAIN"], !domain.isEmpty {
                let suffixes = domain.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard !suffixes.isEmpty, suffixes.count <= 128, suffixes.allSatisfy(Self.domain) else { throw Failure.invalidConfiguration }
                dns["DomainName"] = suffixes[0]
                dns["SearchDomains"] = suffixes
            }
            try install(key + "/IPv4", ["Addresses": [address], "SubnetMasks": ["255.255.255.255"], "InterfaceName": device])
            try install(key + "/DNS", dns)
        }
        journal.ready = true
        try save()
        try run(mode: "--network-verify")
    }

    private func add(_ requested: Route) throws {
        operation = "route_ownership"
        var route = requested
        route.interfaceIndex = if_nametoindex(route.interface)
        guard route.interfaceIndex != 0 else { throw Failure.invalidConfiguration }
        if journal.routes.contains(where: { $0.network == route.network && $0.ipv6 == route.ipv6 }) { return }
        guard journal.routes.count < 2048 else { throw Failure.invalidConfiguration }
        if Self.exact(try lookup(route.network, ipv6: route.ipv6), network: route.network, ipv6: route.ipv6) { throw Failure.conflict }
        journal.routes.append(route)
        try save()
        var arguments = ["-n", "add", route.ipv6 ? "-inet6" : "-inet", "-net", route.network]
        if let gateway = route.gateway { arguments.append(gateway) }
        else { arguments += ["-interface", route.interface] }
        do { try command("/sbin/route", arguments) }
        catch {
            if try !owns(route) {
                journal.routes.removeLast()
                try save()
            }
            throw error
        }
        guard try owns(route) else { throw Failure.verification }
        journal.routes[journal.routes.count - 1].applied = true
        try save()
    }

    private func install(_ key: String, _ dictionary: [String: Any]) throws {
        operation = "dns_install"
        guard !Self.cancelled(directory) else { throw Failure.command }
        guard SCDynamicStoreCopyValue(store, key as CFString) == nil else { throw Failure.conflict }
        guard SCError() == kSCStatusNoKey else { throw Failure.command }
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        journal.values.append(Value(key: key, installed: data))
        try save()
        guard SCDynamicStoreSetValue(store, key as CFString, dictionary as CFDictionary) else { throw Failure.command }
    }

    private func cleanup() throws {
        journal.ready = false
        try save()
        while let value = journal.values.last {
            if try matches(value) {
                guard SCDynamicStoreRemoveValue(store, value.key as CFString) else { throw Failure.command }
            }
            journal.values.removeLast()
            try save()
        }
        while let route = journal.routes.last {
            if try owns(route) {
                guard route.applied || (route.gateway == nil && route.interface == journal.interface) else { throw Failure.conflict }
                var arguments = ["-n", "delete", route.ipv6 ? "-inet6" : "-inet", "-net", route.network]
                if let gateway = route.gateway { arguments.append(gateway) }
                else { arguments += ["-interface", route.interface] }
                try command("/sbin/route", arguments)
                if try owns(route) { throw Failure.verification }
            }
            journal.routes.removeLast()
            try save()
        }
        if let device = journal.interface, if_nametoindex(device) == journal.interfaceIndex {
            let current = try command("/sbin/ifconfig", [device])
            if let address = journal.address, current.contains("inet \(address) ") {
                try command("/sbin/ifconfig", [device, "inet", address, "delete"])
            }
            if let address = journal.address6, current.contains("inet6 \(address) ") {
                try command("/sbin/ifconfig", [device, "inet6", address, "delete"])
            }
        }
        journal.interface = nil
        journal.interfaceIndex = nil
        journal.address = nil
        journal.address6 = nil
        try save()
    }

    private func matches(_ value: Value) throws -> Bool {
        guard let valueInStore = SCDynamicStoreCopyValue(store, value.key as CFString) else {
            guard SCError() == kSCStatusNoKey else { throw Failure.command }
            return false
        }
        guard let current = valueInStore as? NSDictionary else { return false }
        let expected = try PropertyListSerialization.propertyList(from: value.installed, options: [], format: nil)
        return current.isEqual(expected)
    }

    private func owns(_ route: Route) throws -> Bool {
        let expectedIndex = route.interfaceIndex ?? (route.interface == journal.interface ? journal.interfaceIndex : nil)
        guard let expectedIndex, if_nametoindex(route.interface) == expectedIndex else { return false }
        let current = try lookup(route.network, ipv6: route.ipv6)
        guard Self.exact(current, network: route.network, ipv6: route.ipv6),
              current["interface"] == route.interface else { return false }
        return try Self.routeGateway(current, ipv6: route.ipv6) == route.gateway
    }

    private static func routeGateway(_ values: [String: String], ipv6: Bool) throws -> String? {
        guard values["flags"]?.contains("GATEWAY") == true else { return nil }
        guard let gateway = values["gateway"] else { throw Failure.invalidConfiguration }
        let components = gateway.split(separator: "%", omittingEmptySubsequences: false)
        guard components.count <= 2, let address = components.first, ip(String(address), ipv6: ipv6),
              components.count == 1 || (ipv6 && String(components[1]) == values["interface"]) else { throw Failure.invalidConfiguration }
        return gateway
    }

    private func lookup(_ network: String, ipv6: Bool) throws -> [String: String] {
        let result = try command("/sbin/route", ["-n", "get", ipv6 ? "-inet6" : "-inet", "-net", network], allowMissingRoute: true)
        return result.split(separator: "\n").reduce(into: [:]) { values, line in
            if let colon = line.firstIndex(of: ":") {
                values[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private static func exact(_ values: [String: String], network: String, ipv6: Bool) -> Bool {
        let parts = network.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), let rawDestination = values["destination"] else { return false }
        let size = ipv6 ? 16 : 4
        func bytes(_ raw: String) -> [UInt8]? {
            var text = raw
            if text == "default" { text = ipv6 ? "::" : "0.0.0.0" }
            if !ipv6 {
                let components = text.split(separator: ".")
                if components.count < 4 { text += String(repeating: ".0", count: 4 - components.count) }
            }
            var buffer = [UInt8](repeating: 0, count: size)
            guard inet_pton(ipv6 ? AF_INET6 : AF_INET, text, &buffer) == 1 else { return nil }
            return buffer
        }
        guard let wanted = bytes(String(parts[0])), let destination = bytes(rawDestination) else { return false }
        var mask = [UInt8](repeating: 0, count: size)
        for index in 0..<size { let count = min(8, max(0, bits - index * 8)); mask[index] = count == 0 ? 0 : UInt8(256 - (1 << (8 - count))) }
        let actualMask: [UInt8]
        if let rawMask = values["mask"], let parsed = bytes(rawMask) { actualMask = parsed }
        else if values["flags"]?.contains("HOST") == true { actualMask = Array(repeating: 255, count: size) }
        else { return false }
        return mask == actualMask && zip(wanted, mask).map { $0 & $1 } == destination
    }

    private static func ip(_ value: String, ipv6: Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16)
        return value.utf8.count < 64 && inet_pton(ipv6 ? AF_INET6 : AF_INET, value, &buffer) == 1
    }

    private static func domain(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 253 && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-"
                && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }

    private static func bootID() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 128)
        var length = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &length, nil, 0) == 0,
              let value = String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8), UUID(uuidString: value) != nil else {
            throw Failure.journal
        }
        return value
    }

    private func save() throws {
        let bytes = try JSONEncoder().encode(journal)
        try bytes.write(to: journalURL, options: .atomic)
        let descriptor = open(journalURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.journal }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else { throw Failure.journal }
        let parent = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.journal }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw Failure.journal }
    }

    private static func cancelled(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path)
            || !SecureRuntime.engineIsRunning(in: directory)
    }

    @discardableResult private func command(_ path: String, _ arguments: [String], allowMissingRoute: Bool = false) throws -> String {
        operation = path == "/sbin/route" ? "route_" + (arguments.contains("add") ? "add" : arguments.contains("delete") ? "delete" : "lookup") : "interface"
        if configuring && Self.cancelled(directory) { throw Failure.command }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        let timedOut = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let sessionDirectory = directory
        let observesCancellation = configuring
        let cancellation = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        cancellation.schedule(deadline: .now(), repeating: .milliseconds(250))
        cancellation.setEventHandler {
            if observesCancellation && Self.cancelled(sessionDirectory) && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        cancellation.resume()
        defer { cancellation.cancel() }
        try process.run()
        try pipe.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timedOut)
        defer { timedOut.cancel(); cancellation.cancel(); try? pipe.fileHandleForReading.close() }
        var bytes = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            guard bytes.count + chunk.count < 128 * 1024 else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw Failure.command
            }
            bytes.append(chunk)
        }
        process.waitUntilExit()
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.command }
        if process.terminationStatus != 0 {
            if allowMissingRoute && text.contains("not in table") { return "" }
            throw Failure.command
        }
        return text
    }
}

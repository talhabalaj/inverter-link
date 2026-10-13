import Darwin
import Foundation
import Network

enum WiFiNetwork {
    static func current() throws -> ScanScope {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw InverterError.message("Couldn't read the Wi-Fi interface.") }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
                  let netmask = entry.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.bigEndian }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.bigEndian }
            return try ScanScope(local: IPv4(value: ip).text, mask: IPv4(value: mask).text)
        }
        throw InverterError.message("Join the same Wi-Fi network as your inverter, then try again.")
    }
}

// Network callbacks below run on the queue passed to start: .main.
final class UDPProbe {
    private var connection: NWConnection?
    private var waiter: CheckedContinuation<Data?, Never>?
    private var timeout: Task<Void, Never>?
    private var finished = false

    func run(host: String, local: String, port: UInt16, seconds: Double = 1.2) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                waiter = continuation
                let parameters = NWParameters.udp
                parameters.requiredLocalEndpoint = .hostPort(host: .init(local), port: .any)
                let connection = NWConnection(host: .init(host), port: 58899, using: parameters)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        guard let self, !self.finished else { return }
                        switch state {
                        case .ready:
                            connection.send(content: Data("set>server=\(local):\(port);".utf8), completion: .contentProcessed { [weak self] error in
                                MainActor.assumeIsolated {
                                    guard let self, !self.finished else { return }
                                    if error != nil { self.finish(nil); return }
                                    connection.receiveMessage { [weak self] data, _, _, _ in
                                        MainActor.assumeIsolated { self?.finish(data) }
                                    }
                                }
                            })
                        case .failed, .cancelled: self.finish(nil)
                        default: break
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)); self?.finish(nil) } catch { }
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }
    private func finish(_ data: Data?) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: data)
    }
}

final class CallbackServer {
    private let listener: NWListener
    private var expectedIP: String?
    private var ready = false
    private var closed = false
    private var accepted: NWConnection?
    private var readyWaiter: CheckedContinuation<Void, any Error>?
    private var acceptWaiter: CheckedContinuation<NWConnection, any Error>?
    private var readyTimeout: Task<Void, Never>?
    private var acceptTimeout: Task<Void, Never>?
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(local: String, port: NWEndpoint.Port = 8899) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .init(local), port: port)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.readyTimeout?.cancel()
                    let continuation = self.readyWaiter
                    self.readyWaiter = nil
                    continuation?.resume()
                case .failed(let error): self.close(error: error)
                case .cancelled: self.close()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.accepted == nil,
                      case .hostPort(let host, _) = connection.endpoint,
                      String(describing: host) == self.expectedIP else { connection.cancel(); return }
                self.acceptTimeout?.cancel()
                self.accepted = connection
                let continuation = self.acceptWaiter
                self.acceptWaiter = nil
                continuation?.resume(returning: connection)
            }
        }
    }
    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled, !closed else { continuation.resume(throwing: CancellationError()); return }
                readyWaiter = continuation
                readyTimeout = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(5))
                        self?.close(error: InverterError.message("Couldn't open the local listener. Check Local Network access and port 8899."))
                    } catch { }
                }
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func expect(_ ip: String) { expectedIP = ip }
    func accept() async throws -> NWConnection {
        try Task.checkCancellation()
        if let accepted { return accepted }
        guard ready, !closed else { throw InverterError.message("The local listener is unavailable.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !closed else { continuation.resume(throwing: CancellationError()); return }
                acceptWaiter = continuation
                acceptTimeout = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(20))
                        self?.close(error: InverterError.message("No callback from the logger. Check its address, Local Network access and Wi-Fi isolation."))
                    } catch { }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func close(error: any Error = CancellationError()) {
        guard !closed else { return }
        closed = true
        readyTimeout?.cancel()
        acceptTimeout?.cancel()
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        // An accepted connection belongs to the session; stopping discovery must not close it.
        let ready = readyWaiter
        let accept = acceptWaiter
        readyWaiter = nil
        acceptWaiter = nil
        ready?.resume(throwing: error)
        accept?.resume(throwing: error)
    }
}

final class TCPChannel {
    private let connection: NWConnection
    private var decoder = FrameDecoder()
    private var inbox: [TunnelFrame] = []
    private var failure: (any Error)?
    private var ready = false
    private var readyWaiter: CheckedContinuation<Void, any Error>?
    private var frameWaiter: CheckedContinuation<TunnelFrame, any Error>?
    private var sendWaiter: CheckedContinuation<Void, any Error>?
    private var readyTimeout: Task<Void, Never>?
    private var frameTimeout: Task<Void, Never>?
    private var sendTimeout: Task<Void, Never>?

    init(_ connection: NWConnection) { self.connection = connection }
    func checkFailure() throws { if let failure { throw failure } }
    func start() async throws {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.failure == nil else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.readyTimeout?.cancel()
                    let continuation = self.readyWaiter
                    self.readyWaiter = nil
                    continuation?.resume()
                    self.receive()
                case .failed(let error): self.close(error: error)
                case .cancelled: self.close()
                default: break
                }
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); close(); return }
                readyWaiter = continuation
                readyTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)); self?.close(error: InverterError.message("The logger connection timed out.")) } catch { }
                }
                connection.start(queue: .main)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.failure == nil else { return }
                do {
                    if let data {
                        let frames = try self.decoder.append(data)
                        for frame in frames {
                            if let continuation = self.frameWaiter {
                                self.frameWaiter = nil
                                self.frameTimeout?.cancel()
                                continuation.resume(returning: frame)
                            } else {
                                guard self.inbox.count < 32 else { throw InverterError.message("Too many unsolicited logger frames.") }
                                self.inbox.append(frame)
                            }
                        }
                    }
                    if let error { throw error }
                    if complete { throw InverterError.message("The logger disconnected.") }
                    self.receive()
                } catch { self.close(error: error) }
            }
        }
    }
    func send(_ frame: TunnelFrame) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard ready, sendWaiter == nil else { throw InverterError.message("Logger connection is busy.") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); close(); return }
                sendWaiter = continuation
                sendTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(4)); self?.close(error: InverterError.message("Sending to the logger timed out.")) } catch { }
                }
                connection.send(content: frame.data, completion: .contentProcessed { [weak self] error in
                    MainActor.assumeIsolated {
                        guard let self, self.failure == nil else { return }
                        if let error { self.close(error: error); return }
                        self.sendTimeout?.cancel()
                        let continuation = self.sendWaiter
                        self.sendWaiter = nil
                        continuation?.resume()
                    }
                })
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func nextFrame(seconds: Double = 4) async throws -> TunnelFrame {
        try Task.checkCancellation()
        if let failure { throw failure }
        if !inbox.isEmpty { return inbox.removeFirst() }
        guard frameWaiter == nil else { throw InverterError.message("Only one read can run at a time.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); close(); return }
                frameWaiter = continuation
                frameTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)); self?.close(error: InverterError.message("The inverter response timed out.")) } catch { }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func close(error: any Error = CancellationError()) {
        guard failure == nil else { return }
        failure = error
        readyTimeout?.cancel()
        frameTimeout?.cancel()
        sendTimeout?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        let ready = readyWaiter, frame = frameWaiter, send = sendWaiter
        readyWaiter = nil
        frameWaiter = nil
        sendWaiter = nil
        inbox.removeAll()
        ready?.resume(throwing: error)
        frame?.resume(throwing: error)
        send?.resume(throwing: error)
    }
}

enum LoggerScanner {
    static func scan(scope: ScanScope, excluding: Set<String> = [], progress: (Int, Int, String?) -> Void) async throws {
        let server = try CallbackServer(local: scope.local.text)
        defer { server.close() }
        try await server.start()
        let port = server.port
        let hosts = scope.hosts.filter { !excluding.contains($0) }
        await withTaskGroup(of: String?.self) { group in
            var next = 0
            var completed = 0
            func add(_ host: String) {
                group.addTask {
                    let reply = await UDPProbe().run(host: host, local: scope.local.text, port: port)
                    return reply.flatMap { scope.isDiscoveryReply($0, from: host) ? host : nil }
                }
            }
            for host in hosts.prefix(24) { add(host); next += 1 }
            for await found in group {
                if Task.isCancelled { group.cancelAll(); break }
                completed += 1
                progress(completed, hosts.count, found)
                if next < hosts.count { add(hosts[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
    }
}

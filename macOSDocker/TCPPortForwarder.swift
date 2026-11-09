import Foundation
import Darwin

final class TCPPortForwarder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macosdocker.tcp-forwarding", qos: .userInitiated)
    private var listeners: [UInt16: DispatchSourceRead] = [:]
    private var sessions: [UUID: TCPForwardSession] = [:]
    private var destination = ""
    private var closingListeners = 0
    private var revision: UInt64 = 0

    func update(host: String, ports: Set<UInt16>, bindAddress: String = "0.0.0.0", destinationPort: UInt16? = nil, onUpdate: (@Sendable (Set<UInt16>) -> Void)? = nil) {
        queue.async { [self] in
            revision &+= 1
            apply(host: host, ports: ports, bindAddress: bindAddress, destinationPort: destinationPort, onUpdate: onUpdate, revision: revision)
        }
    }

    private func apply(host: String, ports: Set<UInt16>, bindAddress: String, destinationPort: UInt16?, onUpdate: (@Sendable (Set<UInt16>) -> Void)?, revision: UInt64) {
        guard self.revision == revision else { return }
        let key = host + "|" + bindAddress + "|" + String(destinationPort ?? 0)
        if destination != key { reset(); destination = key }
        for port in Array(listeners.keys) where !ports.contains(port) {
            cancelListener(port)
            for session in Array(sessions.values) where session.port == port { session.stop() }
        }
        if closingListeners > 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                guard let self, self.destination == key else { return }
                self.apply(host: host, ports: ports, bindAddress: bindAddress, destinationPort: destinationPort, onUpdate: onUpdate, revision: revision)
            }
            return
        }
        guard !host.isEmpty else { onUpdate?([]); return }
        for port in ports where listeners[port] == nil {
            let family = bindAddress.contains(":") ? AF_INET6 : AF_INET
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            configure(fd)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
            let result: Int32
            if family == AF_INET6 {
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, 4)
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                guard bindAddress.withCString({ inet_pton(AF_INET6, $0, &address.sin6_addr) }) == 1 else { Darwin.close(fd); continue }
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            } else {
                var address = Self.address(bindAddress, port)
                result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            guard result == 0, listen(fd, 128) == 0 else {
                NSLog("TCP forwarding port %u: %@", port, String(cString: strerror(errno)))
                Darwin.close(fd)
                continue
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            listeners[port] = source
            source.setCancelHandler { [weak self] in
                Darwin.close(fd)
                self?.closingListeners -= 1
            }
            source.setEventHandler { [weak self] in
                guard let self else { return }
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { break }
                    guard self.sessions.count < 512 else { Darwin.close(client); continue }
                    let id = UUID()
                    let session = TCPForwardSession(client: client, host: host, port: port, destinationPort: destinationPort ?? port, queue: self.queue) { [weak self] in
                        self?.sessions.removeValue(forKey: id)
                    }
                    self.sessions[id] = session
                    session.start()
                }
            }
            source.resume()
        }
        onUpdate?(Set(listeners.keys))
    }

    func stop() { queue.async { [self] in revision &+= 1; reset(); destination = "" } }

    private func cancelListener(_ port: UInt16) {
        guard let listener = listeners.removeValue(forKey: port) else { return }
        closingListeners += 1
        listener.cancel()
    }

    private func reset() {
        for port in Array(listeners.keys) { cancelListener(port) }
        Array(sessions.values).forEach { $0.stop() }
    }

    fileprivate static func address(_ host: String, _ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        return address
    }
}

private func configure(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)
}

private final class TCPForwardSession {
    let port: UInt16
    private let client: Int32
    private let upstream: Int32
    private let queue: DispatchQueue
    private let host: String
    private let destinationPort: UInt16
    private let finished: () -> Void
    private var connectSource: DispatchSourceWrite?
    private var pumps: [TCPForwardPump] = []
    private var closed = false
    private var ended = 0
    private var timeout: DispatchWorkItem?

    init(client: Int32, host: String, port: UInt16, destinationPort: UInt16, queue: DispatchQueue, finished: @escaping () -> Void) {
        self.client = client
        self.host = host
        self.port = port
        self.destinationPort = destinationPort
        self.queue = queue
        self.finished = finished
        upstream = socket(AF_INET, SOCK_STREAM, 0)
    }

    func start() {
        guard upstream >= 0 else { stop(); return }
        configure(client)
        configure(upstream)
        var address = TCPPortForwarder.address(host, destinationPort)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { connected(); return }
        guard errno == EINPROGRESS else { stop(); return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: upstream, queue: queue)
        connectSource = source
        source.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            var error: Int32 = 0
            var length: socklen_t = 4
            if getsockopt(self.upstream, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 { self.connected() }
            else { self.stop() }
        }
        source.resume()
        let deadline = DispatchWorkItem { [weak self] in self?.stop() }
        timeout = deadline
        queue.asyncAfter(deadline: .now() + 10, execute: deadline)
    }

    private func connected() {
        timeout?.cancel()
        connectSource?.cancel()
        connectSource = nil
        for (source, target) in [(client, upstream), (upstream, client)] {
            let pump = TCPForwardPump(source: source, target: target, queue: queue) { [weak self] success in
                guard let self, !self.closed else { return }
                if !success { self.stop(); return }
                self.ended += 1
                if self.ended == 2 { self.stop() }
            }
            pumps.append(pump)
            pump.start()
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        connectSource?.cancel()
        pumps.forEach { $0.stop() }
        let descriptors = [client, upstream].filter { $0 >= 0 }
        descriptors.forEach { shutdown($0, SHUT_RDWR) }
        queue.async { descriptors.forEach { Darwin.close($0) } }
        finished()
    }
}

private final class TCPForwardPump {
    private let source: Int32
    private let target: Int32
    private let reader: DispatchSourceRead
    private let writer: DispatchSourceWrite
    private let finished: (Bool) -> Void
    private var buffer = [UInt8](repeating: 0, count: 262144)
    private var count = 0
    private var offset = 0
    private var reading = false
    private var writing = false
    private var closed = false

    init(source: Int32, target: Int32, queue: DispatchQueue, finished: @escaping (Bool) -> Void) {
        self.source = source
        self.target = target
        self.finished = finished
        reader = DispatchSource.makeReadSource(fileDescriptor: source, queue: queue)
        writer = DispatchSource.makeWriteSource(fileDescriptor: target, queue: queue)
    }

    func start() {
        reader.setEventHandler { [weak self] in self?.read() }
        writer.setEventHandler { [weak self] in self?.write() }
        reading = true
        reader.resume()
    }

    private func read() {
        guard !closed, count == 0 else { return }
        let received = Darwin.read(source, &buffer, buffer.count)
        if received < 0 {
            if errno != EAGAIN && errno != EINTR { finish(false) }
            return
        }
        if received == 0 { shutdown(target, SHUT_WR); finish(true); return }
        count = received
        offset = 0
        reading = false
        reader.suspend()
        write()
    }

    private func write() {
        guard !closed else { return }
        while offset < count {
            let sent = buffer.withUnsafeBytes { Darwin.write(target, $0.baseAddress!.advanced(by: offset), count - offset) }
            if sent < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    if !writing { writing = true; writer.resume() }
                } else { finish(false) }
                return
            }
            if sent == 0 { finish(false); return }
            offset += sent
        }
        count = 0
        if writing { writing = false; writer.suspend() }
        if !reading { reading = true; reader.resume() }
    }

    private func finish(_ success: Bool) { stop(); finished(success) }

    func stop() {
        guard !closed else { return }
        closed = true
        reader.cancel()
        writer.cancel()
        if !reading { reader.resume() }
        if !writing { writer.resume() }
    }
}

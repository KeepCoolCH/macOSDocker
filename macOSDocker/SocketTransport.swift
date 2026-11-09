import Foundation
import Darwin
import Virtualization

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AppFailure(message: String(localized: "Socket-Pfad ist zu lang.")) }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

private func configureSocket(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
}

final class SocketRelay: @unchecked Sendable {
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var sessions: [UUID: (Int32, VZVirtioSocketConnection)] = [:]
    private var stopped = false
    let path: String
    private let tcp: Bool
    private(set) var port: UInt16 = 0
    init(path: String) { self.path = path; tcp = false }
    init(loopback: Bool) { self.path = ""; tcp = true }

    func start(connect: @escaping @Sendable (@escaping @Sendable (VZVirtioSocketConnection?) -> Void) -> Void) throws {
        let fd = socket(tcp ? AF_INET : AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppFailure(message: String(localized: "Socket konnte nicht erstellt werden.")) }
        let result: Int32
        if tcp {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
            }
            port = UInt16(bigEndian: address.sin_port)
        } else {
            var address: sockaddr_un
            do { address = try unixAddress(path) } catch { Darwin.close(fd); throw error }
            unlink(path)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
        guard result == 0, listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw AppFailure(message: String(localized: "Lokaler Socket konnte nicht geöffnet werden: \(String(cString: strerror(errno)))"))
        }
        if !tcp { chmod(path, 0o600) }
        listener = fd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                configureSocket(client)
                connect { [weak self] connection in
                    guard let self, let connection else { Darwin.close(client); return }
                    self.begin(client, connection)
                }
            }
        }
    }

    private func begin(_ client: Int32, _ connection: VZVirtioSocketConnection) {
        let id = UUID()
        lock.lock()
        guard !stopped else { lock.unlock(); Darwin.close(client); return }
        sessions[id] = (client, connection)
        lock.unlock()
        configureSocket(connection.fileDescriptor)
        let group = DispatchGroup()
        for (source, target) in [(client, connection.fileDescriptor), (connection.fileDescriptor, client)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(source, &buffer, buffer.count)
                    if count <= 0 { break }
                    let sent = buffer.withUnsafeBytes { bytes -> Bool in
                        var offset = 0
                        while offset < count {
                            let n = Darwin.write(target, bytes.baseAddress!.advanced(by: offset), count - offset)
                            if n <= 0 { return false }
                            offset += n
                        }
                        return true
                    }
                    if !sent { break }
                }
                shutdown(target, SHUT_WR)
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility)) { [self, connection] in
            lock.lock()
            sessions.removeValue(forKey: id)
            lock.unlock()
            Darwin.close(client)
            _ = connection
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        if listener >= 0 { shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1 }
        for (_, pair) in sessions { shutdown(pair.0, SHUT_RDWR); shutdown(pair.1.fileDescriptor, SHUT_RDWR) }
        lock.unlock()
        if !tcp { unlink(path) }
    }
}

struct SocketHTTP: Sendable {
    let path: String
    func request(_ method: String = "GET", _ endpoint: String, body: Data? = nil, timeout: Int = 30, acceptedStatuses: Set<Int> = []) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw AppFailure(message: String(localized: "Socket konnte nicht erstellt werden.")) }
            defer { Darwin.close(fd) }
            configureSocket(fd)
            var limit = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout.size(ofValue: limit)))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout.size(ofValue: limit)))
            var address = try unixAddress(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw AppFailure(message: String(localized: "Runtime nicht erreichbar: \(String(cString: strerror(errno)))")) }
            var wire = Data("\(method) \(endpoint) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(body?.count ?? 0)\r\n\r\n".utf8)
            if let body { wire.append(body) }
            try wire.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else { throw AppFailure(message: String(localized: "Socket-Schreibfehler.")) }
                    offset += written
                }
            }
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count == 0 { break }
                guard count > 0 else { throw AppFailure(message: String(localized: "Runtime-Antwort abgebrochen oder Zeitlimit überschritten.")) }
                response.append(buffer, count: count)
                guard response.count <= 64 * 1024 * 1024 else { throw AppFailure(message: String(localized: "Antwort überschreitet 64 MiB; bitte CLI verwenden.")) }
            }
            return try Self.decode(response, acceptedStatuses: acceptedStatuses)
        }.value
    }

    static func decode(_ response: Data, acceptedStatuses: Set<Int> = []) throws -> Data {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw AppFailure(message: String(localized: "Ungültige HTTP-Antwort.")) }
        let header = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let status = Int(header.components(separatedBy: "\r\n")[0].split(separator: " ").dropFirst().first ?? "0") ?? 0
        var payload = Data(response[split.upperBound...])
        if header.lowercased().contains("transfer-encoding: chunked") {
            var decoded = Data()
            while true {
                guard let end = payload.range(of: Data("\r\n".utf8)),
                      let size = Int(String(decoding: payload[..<end.lowerBound], as: UTF8.self).components(separatedBy: ";")[0], radix: 16) else {
                    throw AppFailure(message: String(localized: "Ungültiger HTTP-Chunk."))
                }
                payload = Data(payload[end.upperBound...])
                if size == 0 { break }
                guard size >= 0, payload.count >= size + 2 else { throw AppFailure(message: String(localized: "Unvollständige HTTP-Antwort.")) }
                decoded.append(payload.prefix(size))
                payload = Data(payload.dropFirst(size + 2))
            }
            payload = decoded
        } else if let lengthHeader = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }) {
            guard let length = Int(lengthHeader.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)), length == payload.count else {
                throw AppFailure(message: String(localized: "Unvollständige HTTP-Antwort (Content-Length)."))
            }
        }
        guard (200..<300).contains(status) || acceptedStatuses.contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["message"] as? String
            throw AppFailure(message: "HTTP \(status): \(message ?? String(decoding: payload, as: UTF8.self))")
        }
        return payload
    }
}

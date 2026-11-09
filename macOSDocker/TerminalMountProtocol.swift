import Foundation
import Darwin

struct TerminalMountRequest: Codable, Sendable {
    let binds: [BindRequirement]
    var requireBridge: Bool? = nil
}

struct TerminalMountReply: Codable, Sendable {
    let success: Bool
    let error: String?
}

enum TerminalMountIO {
    static let maximumMessageSize = 1024 * 1024

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AppFailure(message: "Terminal-Mount-Socket-Pfad ist zu lang.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func configure(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func read<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        let prefix = try readExactly(4, from: fd)
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumMessageSize else { throw AppFailure(message: "Ungültige Terminal-Mount-Anfrage.") }
        return try JSONDecoder().decode(type, from: readExactly(count, from: fd))
    }

    static func write<T: Encodable>(_ value: T, to fd: Int32) throws {
        let body = try JSONEncoder().encode(value)
        guard body.count <= maximumMessageSize else { throw AppFailure(message: "Terminal-Mount-Anfrage ist zu gross.") }
        var size = UInt32(body.count).bigEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }
        data.append(body)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AppFailure(message: "Verbindung zur macOSDocker-App unterbrochen.") }
                offset += count
            }
        }
    }

    private static func readExactly(_ size: Int, from fd: Int32) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < size {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), size - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AppFailure(message: "macOSDocker antwortet nicht auf die Mount-Anfrage.") }
                offset += count
            }
        }
        return data
    }
}

import Foundation
import Darwin

final class TerminalMountServer: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: 8)
    private var listener: Int32 = -1
    private var clients = Set<Int32>()
    private var stopped = false

    init(path: String) { self.path = path }

    func start(prepare: @escaping @MainActor @Sendable (TerminalMountRequest) async throws -> Void) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppFailure(message: "Terminal-Mount-Socket konnte nicht erstellt werden.") }
        var address: sockaddr_un
        do { address = try TerminalMountIO.address(path) }
        catch { Darwin.close(fd); throw error }
        TerminalMountIO.configure(fd, seconds: 0)
        unlink(path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            unlink(path)
            throw AppFailure(message: "Terminal-Mount-Socket konnte nicht geöffnet werden.")
        }
        listener = fd
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), slots.wait(timeout: .now()) == .success else { Darwin.close(client); continue }
                lock.lock()
                if stopped { lock.unlock(); slots.signal(); Darwin.close(client); return }
                clients.insert(client)
                lock.unlock()
                TerminalMountIO.configure(client, seconds: 5)
                DispatchQueue.global(qos: .utility).async { [self] in
                    do {
                        let request = try TerminalMountIO.read(TerminalMountRequest.self, from: client)
                        guard request.binds.count <= 256 else { throw AppFailure(message: "Zu viele Terminal-Mounts.") }
                        Task { @MainActor in
                            let reply: TerminalMountReply
                            do { try await prepare(request); reply = TerminalMountReply(success: true, error: nil) }
                            catch { reply = TerminalMountReply(success: false, error: error.localizedDescription) }
                            DispatchQueue.global(qos: .utility).async { [self] in
                                try? TerminalMountIO.write(reply, to: client)
                                finish(client)
                            }
                        }
                    } catch {
                        try? TerminalMountIO.write(TerminalMountReply(success: false, error: error.localizedDescription), to: client)
                        finish(client)
                    }
                }
            }
        }
    }

    private func finish(_ client: Int32) {
        lock.lock()
        clients.remove(client)
        Darwin.close(client)
        lock.unlock()
        slots.signal()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let fd = listener
        listener = -1
        for client in clients { shutdown(client, SHUT_RDWR) }
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        unlink(path)
    }
}

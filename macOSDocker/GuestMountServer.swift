import Foundation
import Virtualization
import Darwin

final class GuestMountServer: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private let prepare: @MainActor @Sendable (TerminalMountRequest) async throws -> Void
    private let lock = NSLock()
    private var connections: [Int32: VZVirtioSocketConnection] = [:]
    private var stopped = false
    let listener = VZVirtioSocketListener()

    init(prepare: @escaping @MainActor @Sendable (TerminalMountRequest) async throws -> Void) {
        self.prepare = prepare
        super.init()
        listener.delegate = self
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, connections.count < 32 else { return false }
        let fd = connection.fileDescriptor
        connections[fd] = connection
        TerminalMountIO.configure(fd, seconds: 5)
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                let request = try TerminalMountIO.read(TerminalMountRequest.self, from: fd)
                guard request.binds.count <= 256 else { throw AppFailure(message: "Zu viele Mac-Bind-Mounts.") }
                Task { @MainActor in
                    let reply: TerminalMountReply
                    do { try await self.prepare(request); reply = TerminalMountReply(success: true, error: nil) }
                    catch { reply = TerminalMountReply(success: false, error: error.localizedDescription) }
                    DispatchQueue.global(qos: .utility).async { [self] in
                        try? TerminalMountIO.write(reply, to: fd)
                        finish(fd)
                    }
                }
            } catch {
                try? TerminalMountIO.write(TerminalMountReply(success: false, error: error.localizedDescription), to: fd)
                finish(fd)
            }
        }
        return true
    }

    private func finish(_ fd: Int32) {
        lock.lock()
        connections.removeValue(forKey: fd)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        for connection in connections.values { shutdown(connection.fileDescriptor, SHUT_RDWR) }
        lock.unlock()
    }
}

@MainActor final class MacBindQueue {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().resume() }
    }
}

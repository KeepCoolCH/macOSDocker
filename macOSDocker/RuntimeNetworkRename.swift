import Foundation

extension RuntimeManager {
    func renameNetwork(_ id: String, to name: String) async throws {
        guard running, !busy, !commandRunning else { throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt.")) }
        busy = true
        defer { busy = false }
        do {
            try await NetworkRename.migrate(id: id, name: name,
                backupDirectory: RuntimeSettings.directory.appendingPathComponent("network-recovery")) { method, endpoint, body in
                try await self.api.request(method, endpoint, body: body)
            }
        } catch {
            try? await refresh()
            throw error
        }
        try await refresh()
    }
}

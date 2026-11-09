import Foundation

extension RuntimeManager {
    func checkEngineUpdate() async throws {
        guard running, !busy, !commandRunning, !engineMaintenance else { return }
        engineMaintenance = true
        defer { engineMaintenance = false }
        engineUpdateAvailable = false
        engineUpdateStatus = String(localized: "Docker-Updates werden geprüft …")
        let version = try JSONSerialization.jsonObject(with: await api.request("GET", "/version")) as? [String: Any]
        engineVersion = version?["Version"] as? String ?? "—"
        let health = try JSONSerialization.jsonObject(with: await control.request("GET", "/health")) as? [String: Any]
        guard (health?["engineUpdateVersion"] as? Int ?? 0) >= 2 else {
            engineUpdateStatus = String(localized: "Für Paketupdates zuerst unter Runtime das Basisimage aktualisieren. Die Docker-Daten bleiben dabei erhalten.")
            return
        }
        do {
            let result = try JSONSerialization.jsonObject(with: await control.request("POST", "/engine-update/check", timeout: 180)) as? [String: Any]
            let checked = EngineUpdateResult(output: result?["updates"] as? String ?? "", installedVersion: engineVersion)
            engineUpdateAvailable = checked.available
            engineUpdateStatus = String(localized: "Installiert: ") + engineVersion + "\n"
                + String(localized: "Verfügbar: ") + checked.availableVersion + "\n"
                + (checked.available ? checked.updates.joined(separator: "\n") : String(localized: "Docker-Pakete sind aktuell."))
        } catch { engineUpdateStatus = error.localizedDescription; throw error }
    }

    private func activeContainerIDs() async throws -> [String] {
        let data = try await api.request("GET", "/containers/json")
        return try JSONDecoder().decode([DockerContainer].self, from: data).map(\.id)
    }
    private func containerState(_ id: String) async throws -> String? {
        let data = try await api.request("GET", "/containers/json?all=1")
        return try JSONDecoder().decode([DockerContainer].self, from: data).first { $0.id == id }?.State
    }
    private func resumeContainers(_ ids: [String]) async throws {
        for id in ids {
            guard let state = try await containerState(id), state != "running" else { continue }
            do {
                _ = try await api.request("POST", "/containers/" + id + "/start", acceptedStatuses: [304])
            } catch {
                let state = try await containerState(id)
                if let state, state != "running" { throw error }
            }
        }
        try await refresh()
    }
    func updateEngine() async throws {
        guard running, !busy, !commandRunning, !engineMaintenance, engineUpdateAvailable else { return }
        engineMaintenance = true
        defer { engineMaintenance = false; engineRecoveryAvailable = EngineRecovery.latest != nil }
        let ids = try await activeContainerIDs()
        engineUpdateStatus = String(localized: "VM wird gestoppt und gesichert …")
        try await stop()
        try await Task.detached(priority: .utility) { try EngineRecovery.snapshot(containers: ids, kind: .engineUpdate) }.value
        engineRecoveryAvailable = true
        try await start()
        engineUpdateStatus = String(localized: "Docker wird aktualisiert …")
        do {
            _ = try await control.request("POST", "/engine-update")
            for _ in 0..<400 {
                try await Task.sleep(for: .seconds(3))
                let value = try JSONSerialization.jsonObject(with: await control.request("GET", "/engine-update")) as? [String: Any]
                if value?["state"] as? String == "failed" { throw AppFailure(message: value?["message"] as? String ?? "Docker update failed") }
                if value?["state"] as? String == "completed" {
                    try await resumeContainers(ids)
                    engineVersion = value?["message"] as? String ?? "—"
                    engineUpdateAvailable = false
                    engineUpdateStatus = String(localized: "Docker wurde aktualisiert. Die Wiederherstellungssicherung bleibt erhalten.")
                    return
                }
            }
            throw AppFailure(message: String(localized: "Zeitüberschreitung beim Docker-Update. Die Sicherung kann über Wiederherstellen zurückgespielt werden."))
        } catch {
            engineUpdateStatus = String(localized: "Docker-Update fehlgeschlagen. Die Sicherung kann über Wiederherstellen zurückgespielt werden.")
            throw error
        }
    }
    func restoreEngineBackup() async throws {
        guard !busy, !commandRunning, !engineMaintenance else { return }
        engineRecoveryAvailable = EngineRecovery.latest != nil
        guard engineRecoveryAvailable else {
            throw AppFailure(message: String(localized: "Keine Wiederherstellungssicherung vorhanden."))
        }
        engineMaintenance = true
        defer { engineMaintenance = false }
        if running { try await stop() }
        let ids = try EngineRecovery.restore()
        if let version = BundledImageInstaller.AppVersion.current {
            try EngineRecovery.locked { try BundledImageInstaller.recordAppVersion(version, at: imageDirectory) }
        }
        baseImageStatus = ""
        try await start()
        try await resumeContainers(ids)
        engineUpdateAvailable = false
        engineVersion = "—"
        engineUpdateStatus = String(localized: "System und Docker-Daten wurden aus der Sicherung wiederhergestellt.")
    }
    func updateBaseImage() async throws {
        guard !busy, !commandRunning, !engineMaintenance else { return }
        engineMaintenance = true
        baseImageUpdating = true
        baseImageStatus = ""
        engineUpdateStatus = ""
        defer { engineMaintenance = false; baseImageUpdating = false; engineRecoveryAvailable = EngineRecovery.latest != nil }
        let wasRunning = running
        let ids = wasRunning ? try await activeContainerIDs() : []
        if wasRunning { try await stop() }
        if FileManager.default.fileExists(atPath: RuntimeSettings.directory.appendingPathComponent("data.raw").path) {
            try await Task.detached(priority: .utility) { try EngineRecovery.snapshot(containers: ids, kind: .baseImage) }.value
        }
        try await updateBundledImage()
        if wasRunning { try await start(); try await resumeContainers(ids) }
        engineVersion = "—"
        engineUpdateAvailable = false
        baseImageStatus = String(localized: "Basisimage aktualisiert. Docker-Daten wurden beibehalten.")
    }
}

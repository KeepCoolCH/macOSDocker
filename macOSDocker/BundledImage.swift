import Foundation
import Darwin

extension RuntimeManager {
    func updateBundledImage() async throws {
        guard !running, !busy else { return }
        busy = true
        defer { busy = false }
        try FileManager.default.createDirectory(at: RuntimeSettings.directory, withIntermediateDirectories: true)
        let fd = Darwin.open(RuntimeSettings.directory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AppFailure(message: String(localized: "Runtime-Sperre nicht verfügbar.")) }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure(message: String(localized: "VM läuft in einem anderen App-Prozess. Dort zuerst stoppen.")) }
        try await prepareBundledImage(replaceExisting: true)
        state = String(localized: "Basisimage aktualisiert")
    }

    func prepareBundledImageForStartup() async throws -> Bool {
        let installed = BundledImageInstaller.isInstalled(at: imageDirectory)
        let outdated = BundledImageInstaller.AppVersion.current.map { BundledImageInstaller.needsAppVersionUpdate(at: imageDirectory, version: $0) } ?? false
        guard installed, outdated else {
            try await prepareBundledImage()
            return false
        }
        let hasData = FileManager.default.fileExists(atPath: RuntimeSettings.directory.appendingPathComponent("data.raw").path)
        if hasData {
            state = String(localized: "Basisimage wird vor dem VM-Start gesichert …")
            try await Task.detached(priority: .utility) {
                try EngineRecovery.snapshotWhileRuntimeLocked(containers: [], kind: .baseImage)
            }.value
            engineRecoveryAvailable = EngineRecovery.latest != nil
        }
        state = String(localized: "Basisimage wird vor dem VM-Start aktualisiert …")
        try await prepareBundledImage(replaceExisting: true)
        baseImageStatus = String(localized: "Basisimage für diese App-Version automatisch aktualisiert. Docker-Daten wurden beibehalten.")
        return hasData
    }

    func prepareBundledImage(replaceExisting: Bool = false) async throws {
        let destination = imageDirectory
        if !replaceExisting && BundledImageInstaller.isInstalled(at: destination) { return }
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("LinuxImage") else {
            throw AppFailure(message: String(localized: "Das mitgelieferte Linux-Basisimage fehlt. Bitte die vollständige App verwenden."))
        }
        let dataDisk = RuntimeSettings.directory.appendingPathComponent("data.raw")
        let appVersion = BundledImageInstaller.AppVersion.current
        state = String(localized: "Linux-Basisimage wird eingerichtet …")
        try await Task.detached(priority: .utility) {
            try BundledImageInstaller.install(from: source, to: destination, dataDisk: dataDisk, replaceExisting: replaceExisting, appVersion: appVersion)
        }.value
    }
}

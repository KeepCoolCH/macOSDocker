import AppKit
import Combine

@MainActor
final class BackupController: ObservableObject {
    private unowned let runtime: RuntimeManager
    @Published var preferences: BackupPreferences { didSet { save() } }
    @Published var entries: [BackupEntry] = []
    @Published var working = false
    @Published private(set) var background = false
    private var ownsMaintenance = false
    @Published var status = ""
    private var timer: AnyCancellable?
    private var listingGeneration = UUID()
    private var retryAfter = Date.distantPast
    private static var file: URL { RuntimeSettings.directory.appendingPathComponent("backups.json") }
    init(runtime: RuntimeManager) {
        self.runtime = runtime
        preferences = (try? JSONDecoder().decode(BackupPreferences.self, from: Data(contentsOf: Self.file))) ?? BackupPreferences()
    }
    var next: Date { preferences.next }
    var available: Bool { !working && !runtime.busy && !runtime.commandRunning && !runtime.engineMaintenance && runtime.activeOperations == 0 }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: RuntimeSettings.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: Self.file, options: .atomic)
        } catch { status = error.localizedDescription }
    }
    func startScheduler() {
        guard timer == nil else { return }
        timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.preferences.isDue(at: Date()), self.retryAfter <= Date(), self.available else { return }
            self.backup(automatic: true)
        }
        reload()
    }
    func reload() {
        let generation = UUID()
        listingGeneration = generation
        guard !preferences.folder.isEmpty else { entries = []; return }
        let folder = URL(fileURLWithPath: preferences.folder)
        Task {
            do {
                let result = try await Task.detached(priority: .utility) { try BackupStore.list(folder) }.value
                guard listingGeneration == generation else { return }
                entries = result
            } catch {
                guard listingGeneration == generation else { return }
                entries = []
                if !working { status = error.localizedDescription }
            }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { preferences.folder = url.path; reload() }
    }
    func clearFolder() {
        guard available else { return }
        var updated = preferences
        updated.folder = ""
        updated.enabled = false
        updated.lastAutomatic = nil
        preferences = updated
        status = ""
        reload()
    }
    func delete(_ entry: BackupEntry) {
        guard available else { return }
        let folder = URL(fileURLWithPath: preferences.folder)
        working = true; background = true; runtime.backupInProgress = true
        status = String(localized: "Backup wird gelöscht …")
        Task {
            defer { working = false; background = false; runtime.backupInProgress = false; reload() }
            do {
                try await Task.detached(priority: .utility) { try BackupStore.delete(entry, from: folder) }.value
                status = String(localized: "Backup wurde gelöscht.")
            } catch { status = error.localizedDescription; runtime.error = status }
        }
    }
    private func launch(_ operation: @escaping () async throws -> Void) {
        guard available else { return }
        status = String(localized: "Bitte warten …")
        working = true; runtime.backupInProgress = true
        ownsMaintenance = true; runtime.engineMaintenance = true
        Task {
            defer {
                working = false; background = false; runtime.backupInProgress = false
                if ownsMaintenance { runtime.engineMaintenance = false; ownsMaintenance = false }
                reload()
            }
            do { try await operation() }
            catch { status = error.localizedDescription; runtime.error = status; retryAfter = Date().addingTimeInterval(300) }
        }
    }
    private func ids() async throws -> [String] {
        try JSONDecoder().decode([DockerContainer].self, from: await runtime.api.request("GET", "/containers/json")).map(\.id)
    }
    private func resume(_ ids: [String]) async throws {
        status = String(localized: "VM wird gestartet …")
        try await runtime.start()
        guard runtime.running else { throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt.")) }
        for id in ids { _ = try await runtime.api.request("POST", "/containers/" + id + "/start", acceptedStatuses: [304]) }
        try await runtime.refresh()
    }
    func backup(automatic: Bool = false) {
        guard !preferences.folder.isEmpty else { return }
        if automatic && preferences.volumesOnly == true { backupVolumes(); return }
        let folder = URL(fileURLWithPath: preferences.folder)
        let settings = runtime.settings
        launch { [self] in
            try await Task.detached(priority: .utility) { try BackupStore.validateDestination(folder) }.value
            let wasRunning = runtime.running
            let active = wasRunning ? try await ids() : []
            status = String(localized: "VM wird gestoppt und gesichert …")
            if wasRunning { try await runtime.stop() }
            var snapshot: BackupStore.Snapshot?
            do {
                status = String(localized: "Lokale APFS-Klonkopie wird erstellt …")
                snapshot = try await Task.detached(priority: .utility) { try BackupStore.snapshot(at: folder) }.value
                if let immutable = snapshot {
                    if wasRunning { try await resume(active) }
                    ownsMaintenance = false; runtime.engineMaintenance = false; background = true
                    status = String(localized: "Klonkopie wird gespeichert und geprüft …")
                    _ = try await Task.detached(priority: .utility) { try BackupStore.create(from: immutable, at: folder, automatic: automatic, ids: active, settings: settings) }.value
                } else {
                    status = String(localized: "Dateisystem unterstützt keine Klone. Normale Sicherung bei gestoppter VM …")
                    _ = try await Task.detached(priority: .utility) { try BackupStore.create(at: folder, automatic: automatic, ids: active, settings: settings) }.value
                    if wasRunning { try await resume(active) }
                }
                if let immutable = snapshot { try await Task.detached(priority: .utility) { try immutable.discard() }.value }
            } catch {
                var failures = [error.localizedDescription]
                if let immutable = snapshot {
                    do { try await Task.detached(priority: .utility) { try immutable.discard() }.value } catch { failures.append(error.localizedDescription) }
                }
                if ownsMaintenance && wasRunning && !runtime.running {
                    do { try await resume(active) } catch { failures.append(error.localizedDescription) }
                }
                throw AppFailure(message: failures.joined(separator: "\n"))
            }
            if automatic { preferences.lastAutomatic = Date() }
            if automatic {
                let keep = preferences.keep
                try await Task.detached(priority: .utility) { try BackupStore.prune(folder, keep: keep) }.value
            }
            status = String(localized: "Backup erfolgreich erstellt und geprüft.")
        }
    }
    func restore(_ source: URL) {
        launch { [self] in
            status = String(localized: "Backup wird geprüft …")
            let verified = try await Task.detached(priority: .utility) { try BackupStore.read(source, verify: true) }.value
            guard verified.kind == nil else { throw AppFailure(message: String(localized: "Diese Sicherung enthält Volume-Archive. Bitte die TAR-Dateien über Volume importieren öffnen.")) }
            let wasRunning = runtime.running
            let active = wasRunning ? try await ids() : []
            status = String(localized: "VM wird gestoppt und gesichert …")
            if wasRunning { try await runtime.stop() }
            do {
                if FileManager.default.fileExists(atPath: RuntimeSettings.directory.appendingPathComponent("data.raw").path) {
                    try await Task.detached(priority: .utility) { try EngineRecovery.snapshot(containers: active, kind: .backupRestore) }.value
                    runtime.engineRecoveryAvailable = EngineRecovery.latest != nil
                }
                status = String(localized: "Backup-Daten werden wiederhergestellt …")
                let manifest = try await Task.detached(priority: .utility) { try BackupStore.restore(source) }.value
                if wasRunning { try await resume(manifest.containers) }
                status = String(localized: "Backup wiederhergestellt. Mac-Freigaben und Adaptereinstellungen dieses Macs bleiben bestehen.")
            } catch {
                throw AppFailure(message: error.localizedDescription + "\n" + String(localized: "Die VM bleibt gestoppt. Eine vorhandene Sicherheitssicherung kann unter Runtime wiederhergestellt werden."))
            }
        }
    }
    private func cli(_ args: [String]) async throws -> CLIResult {
        try await CLIProcess().run(arguments: args, host: "unix://" + runtime.dockerPath).checked()
    }
    func exportVolume(_ name: String, to destination: URL) {
        launch { [self] in try await exportVolumeArchive(name, to: destination) }
    }
    private func exportVolumeArchive(_ name: String, to destination: URL) async throws {
            guard runtime.running else { throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt.")) }
            let helper = "macosdocker-backup-" + UUID().uuidString.lowercased()
            let temp = destination.deletingLastPathComponent().appendingPathComponent(".volume-" + UUID().uuidString + ".tar")
            let inspect = try await cli(["volume", "inspect", name])
            guard let objects = try JSONSerialization.jsonObject(with: inspect.stdout) as? [[String: Any]], let volume = objects.first,
                  volume["Driver"] as? String == "local", (volume["Options"] as? [String: String] ?? [:]).isEmpty else {
                throw AppFailure(message: String(localized: "Nur lokale Docker-Volumes ohne Treiberoptionen können migriert werden."))
            }
            let consumers = try await cli(["ps", "-q", "--filter", "volume=" + name])
            let active = String(decoding: consumers.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            status = String(localized: "Volume wird exportiert …")
            var stopped: [String] = []
            do {
                for id in active { _ = try await cli(["stop", "--time", "30", id]); stopped.append(id) }
                _ = try await cli(["run", "--name", helper, "--network", "none", "--mount", "type=volume,source=" + name + ",target=/source,readonly,volume-nocopy", VolumeMigration.image, "tar", "--create", "--sparse", "--numeric-owner", "--acls", "--xattrs", "--xattrs-include=*", "-f", "/backup.tar", "-C", "/source", "."])
                _ = try await cli(["cp", helper + ":/backup.tar", temp.path])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                _ = try? await cli(["rm", "-f", helper])
                try? FileManager.default.removeItem(at: temp)
                var errors = [error.localizedDescription]
                for id in stopped { do { _ = try await cli(["start", id]) } catch { errors.append(error.localizedDescription) } }
                throw AppFailure(message: errors.joined(separator: "\n"))
            }
            var recoveryErrors: [String] = []
            do { _ = try await cli(["rm", helper]) } catch { recoveryErrors.append(error.localizedDescription) }
            for id in stopped {
                do { _ = try await cli(["start", id]) } catch { recoveryErrors.append(error.localizedDescription) }
            }
            if !recoveryErrors.isEmpty { throw AppFailure(message: recoveryErrors.joined(separator: "\n")) }
            status = String(localized: "Volume erfolgreich exportiert.")
    }
    private func backupVolumes() {
        let folder = URL(fileURLWithPath: preferences.folder)
        launch { [self] in
            let fm = FileManager.default
            guard fm.fileExists(atPath: folder.path) else { throw CocoaError(.fileNoSuchFile) }
            let root = RuntimeSettings.directory.resolvingSymlinksInPath().path
            let target = folder.resolvingSymlinksInPath().path
            guard target != root, !target.hasPrefix(root + "/") else { throw AppFailure(message: String(localized: "Backup-Ziel muss ausserhalb des Runtime-Ordners liegen.")) }
            let wasRunning = runtime.running
            if !wasRunning { try await runtime.start() }
            var stopped: [String] = []
            var manifest = BackupManifest(automatic: true, containers: [], settings: runtime.settings, hashes: [:])
            manifest.kind = "volumes"
            let staging = folder.appendingPathComponent(".backup-" + manifest.id.uuidString)
            do {
                let data = try await runtime.api.request("GET", "/volumes")
                let names = try JSONDecoder().decode(VolumeList.self, from: data).Volumes?.map(\.Name).sorted() ?? []
                for id in try await ids() { _ = try await cli(["stop", "--time", "30", id]); stopped.append(id) }
                try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                for name in names {
                    try VolumeMigration.validate(source: "", destination: name)
                    let archive = staging.appendingPathComponent(name + ".tar")
                    try await exportVolumeArchive(name, to: archive)
                    status = String(localized: "Backup-Daten werden kopiert und geprüft …")
                    manifest.hashes[name + ".tar"] = try await Task.detached(priority: .utility) { try BackupStore.digest(archive) }.value
                }
                try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("backup.json"), options: .atomic)
                _ = try await Task.detached(priority: .utility) { try BackupStore.read(staging, verify: true) }.value
                try fm.moveItem(at: staging, to: folder.appendingPathComponent(manifest.id.uuidString + ".macosdockerbackup"))
            } catch {
                try? fm.removeItem(at: staging)
                var errors = [error.localizedDescription]
                if wasRunning {
                    for id in stopped { do { _ = try await cli(["start", id]) } catch { errors.append(error.localizedDescription) } }
                } else { do { try await runtime.stop() } catch { errors.append(error.localizedDescription) } }
                throw AppFailure(message: errors.joined(separator: "\n"))
            }
            preferences.lastAutomatic = Date()
            if wasRunning { try await resume(stopped) } else { try await runtime.stop() }
            let keep = preferences.keep
            try await Task.detached(priority: .utility) { try BackupStore.prune(folder, keep: keep, volumesOnly: true) }.value
            status = String(localized: "Backup erfolgreich erstellt und geprüft.")
        }
    }
    func importVolume(from archive: URL, name: String) {
        launch { [self] in
            guard runtime.running else { throw AppFailure(message: String(localized: "Runtime ist beschäftigt oder gestoppt.")) }
            try VolumeMigration.validate(source: "", destination: name)
            let volumes = try await cli(["volume", "ls", "--format", "{{.Name}}"])
            guard !String(decoding: volumes.stdout, as: UTF8.self).split(separator: "\n").contains(Substring(name)) else { throw AppFailure(message: String(localized: "Der neue Volume-Name existiert bereits.")) }
            let helper = "macosdocker-import-" + UUID().uuidString.lowercased()
            status = String(localized: "Volume wird importiert …")
            let marker = UUID().uuidString
            _ = try await cli(["volume", "create", "--label", "com.macosdocker.import=" + marker, name])
            let inspection = try await cli(["volume", "inspect", name])
            guard let items = try JSONSerialization.jsonObject(with: inspection.stdout) as? [[String: Any]],
                  (items.first?["Labels"] as? [String: String])?["com.macosdocker.import"] == marker else { throw AppFailure(message: String(localized: "Der neue Volume-Name existiert bereits.")) }
            do {
                _ = try await cli(["create", "--name", helper, "--network", "none", "--mount", "type=volume,source=" + name + ",target=/destination,volume-nocopy", VolumeMigration.image, "bash", "-c", "set -e; test -z \"$(ls -A /destination)\"; tar --extract --numeric-owner --same-owner --acls --xattrs --xattrs-include='*' -f /backup.tar -C /destination; sync"])
                _ = try await cli(["cp", archive.path, helper + ":/backup.tar"])
                _ = try await cli(["start", "--attach", helper])
                let result = try await cli(["inspect", "--format", "{{.State.ExitCode}}", helper])
                guard String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                _ = try? await cli(["rm", "-f", helper])
                throw AppFailure(message: error.localizedDescription + "\n" + String(localized: "Das neue Volume bleibt zur Prüfung erhalten: ") + name)
            }
            _ = try await cli(["rm", helper])
            try await runtime.refresh()
            status = String(localized: "Volume erfolgreich importiert. Container können jetzt damit verbunden werden.")
        }
    }
}

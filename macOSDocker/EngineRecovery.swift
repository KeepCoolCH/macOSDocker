import Foundation
import Darwin

enum EngineRecovery {
    enum Kind: String, CaseIterable {
        case engineUpdate = "engine-update"
        case baseImage = "base-image"
        case backupRestore = "backup-restore"
    }
    static var root: URL { RuntimeSettings.directory.appendingPathComponent("engine-recovery") }
    static func latest(for kind: Kind) -> URL? {
        guard let name = try? String(contentsOf: root.appendingPathComponent("latest-" + kind.rawValue), encoding: .utf8),
              UUID(uuidString: name) != nil else { return nil }
        let path = root.appendingPathComponent(name)
        return completeSnapshot(path) ? path : nil
    }
    static var latest: URL? {
        Kind.allCases.compactMap { latest(for: $0) }.max {
            let left = (try? $0.appendingPathComponent("manifest.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.appendingPathComponent("manifest.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
        }
    }
    static func locked<T>(_ operation: () throws -> T) throws -> T {
        let fd = Darwin.open(RuntimeSettings.directory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AppFailure(message: String(localized: "Runtime-Sperre nicht verfügbar.")) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure(message: String(localized: "VM läuft in einem anderen App-Prozess. Dort zuerst stoppen.")) }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    private static func clone(_ source: URL, _ destination: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try clone(file, destination.appendingPathComponent(file.lastPathComponent))
            }
            return
        }
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw AppFailure(message: String(localized: "Sicherung benötigt ein Dateisystem mit APFS-Klonunterstützung und ausreichend freien Speicher: ") + String(cString: strerror(errno)))
        }
    }
    private static func regularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private static func directory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    private static func completeImage(_ url: URL) -> Bool {
        directory(url) && ["vmlinuz", "initramfs", "system.raw"].allSatisfy { regularFile(url.appendingPathComponent($0)) }
    }
    private static func completeSnapshot(_ url: URL) -> Bool {
        guard directory(url), completeImage(url.appendingPathComponent("image")), regularFile(url.appendingPathComponent("data.raw")),
              regularFile(url.appendingPathComponent("manifest.json")),
              let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
              (try? JSONDecoder().decode([String].self, from: data)) != nil else { return false }
        return true
    }
    static func pruneWhileRuntimeLocked() {
        do { try prune() }
        catch { NSLog("Recovery cleanup: %@", error.localizedDescription) }
    }
    private static func prune() throws {
        let fm = FileManager.default
        guard directory(root), completeImage(RuntimeSettings.directory.appendingPathComponent("image")),
              regularFile(RuntimeSettings.directory.appendingPathComponent("data.raw")) else { return }
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        var retained = Set<String>()
        for marker in entries where marker.lastPathComponent.hasPrefix("latest-") {
            guard regularFile(marker), let name = try? String(contentsOf: marker, encoding: .utf8),
                  UUID(uuidString: name) != nil, completeSnapshot(root.appendingPathComponent(name)) else { return }
            retained.insert(name)
        }
        guard !retained.isEmpty else { return }
        let restores = entries.filter { folder in
            let name = folder.lastPathComponent
            guard name.hasPrefix("restore-"), UUID(uuidString: String(name.dropFirst(8))) != nil, directory(folder),
                  let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                  Set(children.map(\.lastPathComponent)) == Set(["previous-image", "previous-data.raw"]),
                  completeImage(folder.appendingPathComponent("previous-image")), regularFile(folder.appendingPathComponent("previous-data.raw")) else { return false }
            return true
        }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left > right
        }
        for folder in entries where UUID(uuidString: folder.lastPathComponent) != nil && !retained.contains(folder.lastPathComponent) && completeSnapshot(folder) {
            try fm.removeItem(at: folder)
        }
        for folder in restores.dropFirst() { try fm.removeItem(at: folder) }
    }
    static func snapshot(containers: [String], kind: Kind) throws {
        try locked { try snapshotWhileRuntimeLocked(containers: containers, kind: kind) }
    }
    static func snapshotWhileRuntimeLocked(containers: [String], kind: Kind) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var completed = false
        defer { if !completed { try? fm.removeItem(at: folder) } }
        try clone(RuntimeSettings.directory.appendingPathComponent("image"), folder.appendingPathComponent("image"))
        try clone(RuntimeSettings.directory.appendingPathComponent("data.raw"), folder.appendingPathComponent("data.raw"))
        try JSONEncoder().encode(containers).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        guard completeSnapshot(folder) else { throw AppFailure(message: String(localized: "Die Wiederherstellungssicherung ist unvollständig.")) }
        try folder.lastPathComponent.write(to: root.appendingPathComponent("latest-" + kind.rawValue), atomically: true, encoding: .utf8)
        completed = true
        pruneWhileRuntimeLocked()
    }
    static func restore(kind: Kind? = nil) throws -> [String] {
        try locked {
            guard let source = kind.flatMap({ latest(for: $0) }) ?? (kind == nil ? latest : nil) else { throw AppFailure(message: String(localized: "Keine Wiederherstellungssicherung vorhanden.")) }
            let fm = FileManager.default
            let containers = try JSONDecoder().decode([String].self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
            let staging = root.appendingPathComponent("restore-" + UUID().uuidString)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for name in ["image", "data.raw"] { try clone(source.appendingPathComponent(name), staging.appendingPathComponent(name)) }
            var moved: [String] = []
            do {
                for name in ["image", "data.raw"] {
                    let current = RuntimeSettings.directory.appendingPathComponent(name)
                    try fm.moveItem(at: current, to: staging.appendingPathComponent("previous-" + name))
                    moved.append(name)
                    try fm.moveItem(at: staging.appendingPathComponent(name), to: current)
                }
            } catch {
                for name in moved.reversed() {
                    let current = RuntimeSettings.directory.appendingPathComponent(name)
                    if fm.fileExists(atPath: current.path) { try? fm.moveItem(at: current, to: staging.appendingPathComponent("failed-" + name)) }
                    try? fm.moveItem(at: staging.appendingPathComponent("previous-" + name), to: current)
                }
                throw error
            }
            return containers
        }
    }
}

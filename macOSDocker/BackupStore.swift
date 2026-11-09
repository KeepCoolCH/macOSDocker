import Foundation
import CryptoKit
import Darwin

struct BackupPreferences: Codable {
    var folder = ""
    var enabled = false
    var hours = 24
    var intervalUnit: String?
    var volumesOnly: Bool?
    var keep = 7
    var lastAutomatic: Date?
    var enabledAt = Date()
    var next: Date {
        let component: Calendar.Component
        switch intervalUnit ?? "hours" {
        case "days": component = .day
        case "weeks": component = .weekOfYear
        case "months": component = .month
        default: component = .hour
        }
        return Calendar.current.date(byAdding: component, value: max(1, hours), to: lastAutomatic ?? enabledAt) ?? .distantFuture
    }
    func isDue(at date: Date) -> Bool { enabled && !folder.isEmpty && next <= date }
}

struct BackupManifest: Codable {
    var kind: String?
    var format = 1
    var id = UUID()
    var created = Date()
    var automatic: Bool
    var containers: [String]
    var settings: RuntimeSettings
    var hashes: [String: String]
}
struct BackupEntry: Identifiable {
    let url: URL
    let manifest: BackupManifest
    var id: UUID { manifest.id }
}

enum BackupStore {
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func files(_ directory: URL) throws -> [String] {
        let root = directory.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard let iterator = fm.enumerator(atPath: root.path) else { throw CocoaError(.fileReadUnknown) }
        var result: [String] = []
        for case let name as String in iterator {
            let url = root.appendingPathComponent(name)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw AppFailure(message: String(localized: "Backup enthält unerlaubte symbolische Links.")) }
            if url.lastPathComponent == ".DS_Store" { continue }
            if info.isRegularFile == true { result.append(name) }
        }
        return result.sorted()
    }
    static func read(_ url: URL, verify: Bool = false) throws -> BackupManifest {
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard info.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: url.appendingPathComponent("backup.json")))
        guard manifest.format == 1,
              (manifest.kind == "volumes" ? manifest.hashes.keys.allSatisfy({ $0.hasSuffix(".tar") && !$0.contains("/") }) : (manifest.kind == nil && manifest.hashes["data.raw"] != nil && manifest.hashes.keys.contains(where: { $0.hasPrefix("image/") }))) else { throw CocoaError(.fileReadCorruptFile) }
        if verify {
            let names = try files(url).filter { $0 != "backup.json" }
            let expected = Set(manifest.hashes.keys.filter { URL(fileURLWithPath: $0).lastPathComponent != ".DS_Store" })
            let missing = expected.subtracting(names).sorted()
            let extra = Set(names).subtracting(expected).sorted()
            guard missing.isEmpty && extra.isEmpty else {
                throw AppFailure(message: String(localized: "Backup-Dateiliste stimmt nicht überein. Fehlende Dateien: ") + missing.joined(separator: ", ")
                    + String(localized: "; zusätzliche Dateien: ") + extra.joined(separator: ", "))
            }
            for name in names {
                guard try digest(url.appendingPathComponent(name)) == manifest.hashes[name] else { throw AppFailure(message: String(localized: "Backup-Prüfsumme stimmt nicht überein: ") + name) }
            }
        }
        return manifest
    }
    static func list(_ folder: URL) throws -> [BackupEntry] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "macosdockerbackup" }
            .compactMap { url in (try? read(url)).map { BackupEntry(url: url, manifest: $0) } }
            .sorted { $0.manifest.created > $1.manifest.created }
    }
    struct Snapshot {
        fileprivate let directory: URL
        func discard() throws {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { }
        }
    }
    static func validateDestination(_ folder: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else { throw CocoaError(.fileNoSuchFile) }
        let source = RuntimeSettings.directory.resolvingSymlinksInPath().path
        let target = folder.resolvingSymlinksInPath().path
        guard target != source, !target.hasPrefix(source + "/") else { throw AppFailure(message: String(localized: "Backup-Ziel muss ausserhalb des Runtime-Ordners liegen.")) }
    }
    static func snapshot(at destination: URL? = nil, clone: (URL, URL) throws -> Void = cloneFile) throws -> Snapshot? {
        try EngineRecovery.locked {
            let fm = FileManager.default
            var parent = RuntimeSettings.directory
            if let destination {
                try validateDestination(destination)
                var sourceInfo = stat(), targetInfo = stat()
                guard stat(RuntimeSettings.directory.path, &sourceInfo) == 0, stat(destination.path, &targetInfo) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if sourceInfo.st_dev == targetInfo.st_dev { parent = destination }
            }
            let directory = parent.appendingPathComponent(".backup-snapshot-" + UUID().uuidString)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            func copy(_ source: URL, _ target: URL) throws {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
                if values.isDirectory == true {
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                    for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                        try copy(child, target.appendingPathComponent(child.lastPathComponent))
                    }
                } else { try clone(source, target) }
            }
            do {
                for name in ["image", "data.raw"] { try copy(RuntimeSettings.directory.appendingPathComponent(name), directory.appendingPathComponent(name)) }
                return Snapshot(directory: directory)
            } catch {
                try fm.removeItem(at: directory)
                let failure = error as NSError
                if failure.domain == NSPOSIXErrorDomain && [Int(ENOTSUP), Int(EXDEV), Int(ENOSYS)].contains(failure.code) { return nil }
                throw error
            }
        }
    }
    private static func cloneFile(_ source: URL, _ target: URL) throws {
        guard clonefile(source.path, target.path, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    static func create(at folder: URL, automatic: Bool, ids: [String], settings: RuntimeSettings) throws -> URL {
        try EngineRecovery.locked {
            try writeBackup(from: RuntimeSettings.directory, at: folder, automatic: automatic, ids: ids, settings: settings)
        }
    }
    static func create(from snapshot: Snapshot, at folder: URL, automatic: Bool, ids: [String], settings: RuntimeSettings) throws -> URL {
        try validateDestination(folder)
        if snapshot.directory.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() {
            return try finishBackup(staging: snapshot.directory, at: folder, automatic: automatic, ids: ids, settings: settings)
        }
        return try writeBackup(from: snapshot.directory, at: folder, automatic: automatic, ids: ids, settings: settings)
    }
    private static func writeBackup(from source: URL, at folder: URL, automatic: Bool, ids: [String], settings: RuntimeSettings) throws -> URL {
        try validateDestination(folder)
        let fm = FileManager.default
        let staging = folder.appendingPathComponent(".backup-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        for name in ["image", "data.raw"] {
            try fm.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        return try finishBackup(staging: staging, at: folder, automatic: automatic, ids: ids, settings: settings)
    }
    private static func finishBackup(staging: URL, at folder: URL, automatic: Bool, ids: [String], settings: RuntimeSettings) throws -> URL {
        let fm = FileManager.default
        var manifest = BackupManifest(automatic: automatic, containers: ids, settings: settings, hashes: [:])
        for name in try files(staging) { manifest.hashes[name] = try digest(staging.appendingPathComponent(name)) }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("backup.json"), options: .atomic)
        _ = try read(staging, verify: true)
        let final = folder.appendingPathComponent(manifest.id.uuidString + ".macosdockerbackup")
        try fm.moveItem(at: staging, to: final)
        return final
    }
    static func delete(_ entry: BackupEntry, from folder: URL) throws {
        guard entry.url.pathExtension == "macosdockerbackup",
              entry.url.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath(),
              try read(entry.url).id == entry.id else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.removeItem(at: entry.url)
    }
    static func prune(_ folder: URL, keep: Int, volumesOnly: Bool = false) throws {
        for entry in try list(folder).filter({ $0.manifest.automatic && ($0.manifest.kind == "volumes") == volumesOnly }).dropFirst(max(1, keep)) {
            try FileManager.default.removeItem(at: entry.url)
        }
    }
    static func restore(_ source: URL) throws -> BackupManifest {
        try EngineRecovery.locked {
            let manifest = try read(source, verify: true)
            guard manifest.kind == nil else { throw AppFailure(message: String(localized: "Diese Sicherung enthält Volume-Archive. Bitte die TAR-Dateien über Volume importieren öffnen.")) }
            let fm = FileManager.default
            let staging = RuntimeSettings.directory.appendingPathComponent("backup-restore-" + UUID().uuidString)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in ["image", "data.raw"] { try fm.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name)) }
            for (name, expected) in manifest.hashes where URL(fileURLWithPath: name).lastPathComponent != ".DS_Store" {
                guard try digest(staging.appendingPathComponent(name)) == expected else { throw CocoaError(.fileReadCorruptFile) }
            }
            var moved: [String] = []
            do {
                for name in ["image", "data.raw"] {
                    let current = RuntimeSettings.directory.appendingPathComponent(name)
                    if fm.fileExists(atPath: current.path) { try fm.moveItem(at: current, to: staging.appendingPathComponent("previous-" + name)) }
                    moved.append(name)
                    try fm.moveItem(at: staging.appendingPathComponent(name), to: current)
                }
            } catch {
                for name in moved.reversed() {
                    let current = RuntimeSettings.directory.appendingPathComponent(name)
                    try? fm.removeItem(at: current)
                    let previous = staging.appendingPathComponent("previous-" + name)
                    if fm.fileExists(atPath: previous.path) { try fm.moveItem(at: previous, to: current) }
                }
                throw error
            }
            return manifest
        }
    }
}

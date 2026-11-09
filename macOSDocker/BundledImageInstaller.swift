import Foundation

enum BundledImageInstaller {
    struct AppVersion: Codable, Equatable, Sendable {
        let version: String
        let build: Int
        var directorySharingVersion: Int? = nil
        static var current: Self? {
            guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init), build > 0 else { return nil }
            return Self(version: version, build: build, directorySharingVersion: 2)
        }
    }
    private static let versionFile = "installed-app-version.json"
    private static let imageFiles = ["vmlinuz", "initramfs", "system.raw"]

    static func isInstalled(at directory: URL) -> Bool {
        imageFiles.allSatisfy { name in
            guard let values = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    static func needsAppVersionUpdate(at directory: URL, version: AppVersion) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(versionFile)),
              let installed = try? JSONDecoder().decode(AppVersion.self, from: data) else { return true }
        return version.build > installed.build || (version.build == installed.build && (version.version != installed.version || version.directorySharingVersion != installed.directorySharingVersion))
    }

    static func recordAppVersion(_ version: AppVersion, at directory: URL) throws {
        try JSONEncoder().encode(version).write(to: directory.appendingPathComponent(versionFile), options: .atomic)
    }

    static func install(from source: URL, to destination: URL, dataDisk: URL, replaceExisting: Bool = false, appVersion: AppVersion? = nil) throws {
        let fm = FileManager.default
        if !replaceExisting && isInstalled(at: destination) { return }
        if !replaceExisting && fm.fileExists(atPath: dataDisk.path) {
            throw AppFailure(message: String(localized: "Vorhandenes Linux-Image ist unvollständig. Unter Runtime das Basisimage aktualisieren."))
        }
        for name in ["vmlinuz", "initramfs", "system.raw.gz"] {
            guard let values = try? source.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw AppFailure(message: String(localized: "Das mitgelieferte Linux-Basisimage fehlt. Bitte die vollständige App verwenden."))
            }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent("image-install-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        for name in ["vmlinuz", "initramfs"] { try fm.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name)) }
        let disk = staging.appendingPathComponent("system.raw")
        guard fm.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AppFailure(message: String(localized: "Linux-Basisimage konnte nicht entpackt werden."))
        }
        let output = try FileHandle(forWritingTo: disk)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", source.appendingPathComponent("system.raw.gz").path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, isInstalled(at: staging) else {
            throw AppFailure(message: String(localized: "Linux-Basisimage konnte nicht entpackt werden."))
        }
        try Data().write(to: staging.appendingPathComponent("multiple-directory-sharing"))
        if let appVersion {
            try recordAppVersion(appVersion, at: staging)
        }
        if fm.fileExists(atPath: destination.path) {
            let previous = destination.deletingLastPathComponent().appendingPathComponent("image-install-previous-" + UUID().uuidString)
            try fm.moveItem(at: destination, to: previous)
            do { try fm.moveItem(at: staging, to: destination) }
            catch {
                try fm.moveItem(at: previous, to: destination)
                throw error
            }
            try? fm.removeItem(at: previous)
        } else { try fm.moveItem(at: staging, to: destination) }
    }
}

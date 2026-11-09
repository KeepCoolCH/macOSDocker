import Foundation

struct PreparedCompose {
    let arguments: [String]
    let directory: URL
    let binds: [BindRequirement]
    let serviceCount: Int
}

enum ComposeLauncher {
    static func prepare(yaml: String?, command: String?, project: String, directory: URL, host: String,
                        job: CLIProcess) async throws -> PreparedCompose {
        var workingDirectory = directory
        var globals: [(String, String?)] = []
        var up: [String] = ["-d"]
        if let yaml {
            guard project.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil else { throw AppFailure(message: String(localized: "Compose-Projektname: Kleinbuchstaben, Ziffern, Unterstrich und Bindestrich verwenden.")) }
            guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure(message: String(localized: "Compose-Inhalt fehlt.")) }
            let input = RuntimeSettings.directory.appendingPathComponent("compose-projects/\(project)/compose.yaml")
            try writePrivate(Data(yaml.utf8), to: input)
            globals = [("project-name", project), ("file", input.path)]
        } else if let command {
            var words = try CommandWords.parse(command, directory: directory)
            if words.first == "docker-compose" { words.removeFirst() }
            else {
                guard words.count >= 2 && words[0] == "docker" && words[1] == "compose" else { throw AppFailure(message: String(localized: "Bitte docker compose … up eingeben.")) }
                words.removeFirst(2)
            }
            let help = try await job.run(arguments: ["compose", "--help"]).checked()
            let parsed = try CLIOptions(help: String(decoding: help.stdout, as: UTF8.self)).parse(words)
            guard parsed.remainder.first == "up" else { throw AppFailure(message: String(localized: "Dieser Startdialog unterstützt docker compose … up. Andere Compose-Aktionen sind im Terminal verfügbar.")) }
            globals = parsed.options
            up = Array(parsed.remainder.dropFirst())
            if let path = globals.last(where: { $0.0 == "project-directory" })?.1 {
                workingDirectory = URL(fileURLWithPath: DockerRunParser.resolve(path, directory: directory), isDirectory: true)
            }
            for index in globals.indices {
                let (name, value) = globals[index]
                if name == "file" {
                    guard let value, value != "-", !value.contains("://") else { throw AppFailure(message: String(localized: "Bitte eine lokale Compose-Datei verwenden; eingefügter Inhalt gehört in den Modus Compose-YAML.")) }
                    globals[index].1 = DockerRunParser.resolve(value, directory: directory)
                } else if name == "env-file", let value { globals[index].1 = DockerRunParser.resolve(value, directory: directory) }
                else if name == "project-directory" { globals[index].1 = workingDirectory.path }
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AppFailure(message: String(localized: "Arbeitsordner ist nicht verfügbar.")) }
        let prefix = ["compose", "--ansi", "never", "--project-directory", workingDirectory.path]
        let normalized = try await job.run(arguments: prefix + CLIOptions.arguments(globals) + ["config", "--format", "json"], host: host, directory: workingDirectory).checked()
        guard !normalized.truncated else { throw AppFailure(message: String(localized: "Compose-Konfiguration ist zu groß.")) }
        guard var model = try JSONSerialization.jsonObject(with: normalized.stdout) as? [String: Any], var services = model["services"] as? [String: [String: Any]] else {
            throw AppFailure(message: String(localized: "Compose liefert keine gültigen Services."))
        }
        var binds: [BindRequirement] = []
        for name in services.keys {
            if var mounts = services[name]?["volumes"] as? [[String: Any]] {
                for index in mounts.indices where mounts[index]["type"] as? String == "bind" {
                    if let source = mounts[index]["source"] as? String {
                        let path = DockerRunParser.resolve(source, directory: workingDirectory)
                        mounts[index]["source"] = path
                        binds.append(BindRequirement(source: path, readOnly: mounts[index]["read_only"] as? Bool ?? false))
                    }
                }
                services[name]?["volumes"] = mounts
            }
        }
        model["services"] = services
        for category in ["secrets", "configs"] {
            var definitions = model[category] as? [String: [String: Any]] ?? [:]
            let used = services.values.flatMap { ($0[category] as? [[String: Any]] ?? []).compactMap { $0["source"] as? String } }
            for name in Set(used) {
                if let file = definitions[name]?["file"] as? String {
                    let path = DockerRunParser.resolve(file, directory: workingDirectory)
                    definitions[name]?["file"] = path
                    binds.append(BindRequirement(source: path, readOnly: true))
                }
            }
            if !definitions.isEmpty { model[category] = definitions }
        }
        let resolvedName = model["name"] as? String ?? project
        guard resolvedName.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil else { throw AppFailure(message: String(localized: "Ungültiger aufgelöster Compose-Projektname.")) }
        let snapshot = RuntimeSettings.directory.appendingPathComponent("compose-projects/\(resolvedName)/compose.resolved.json")
        let snapshotData = try JSONSerialization.data(withJSONObject: model, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writePrivate(snapshotData, to: snapshot)
        let retained = globals.filter { !["file", "env-file", "project-directory", "ansi", "progress"].contains($0.0) }
        return PreparedCompose(arguments: prefix + ["--progress", "plain"] + CLIOptions.arguments(retained) + ["--file", snapshot.path, "up"] + up,
                               directory: workingDirectory, binds: binds, serviceCount: services.count)
    }
    private static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AppFailure(message: String(localized: "Compose-Datei konnte nicht erstellt werden.")) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
}

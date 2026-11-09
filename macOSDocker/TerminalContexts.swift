import Foundation

@MainActor
extension RuntimeManager {
    private var userDockerConfiguration: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker")
    }
    private func terminalCLI(_ arguments: [String]) async throws -> Data {
        try await CLIProcess().run(arguments: ["--config", userDockerConfiguration.path] + arguments).checked().stdout
    }
    func loadTerminalContexts() async throws {
        let data = try await terminalCLI(["context", "ls", "--format", "{{.Name}}"])
        let names = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        terminalContexts = Array(Set(names + ["macosdocker"])).sorted()
        let current = try await terminalCLI(["context", "show"])
        terminalContext = String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func selectTerminalContext(_ name: String) async throws {
        guard terminalContexts.contains(name) else { return }
        if name == "macosdocker" {
            let names = String(decoding: try await terminalCLI(["context", "ls", "--format", "{{.Name}}"]), as: UTF8.self).split(whereSeparator: \.isNewline)
            if names.contains("macosdocker") {
                let data = try await terminalCLI(["context", "inspect", name])
                let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                let endpoints = objects?.first?["Endpoints"] as? [String: [String: Any]]
                guard endpoints?["docker"]?["Host"] as? String == "unix://" + dockerPath else {
                    throw AppFailure(message: String(localized: "Ein anderer Docker-Context namens macosdocker existiert bereits. Bitte diesen im Terminal umbenennen; er wird nicht überschrieben."))
                }
            } else {
                _ = try await terminalCLI(["context", "create", name, "--description", "macOSDocker Linux runtime", "--docker", "host=unix://" + dockerPath])
            }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: userDockerConfiguration, withIntermediateDirectories: true)
        let file = userDockerConfiguration.appendingPathComponent("config.json")
        var config: [String: Any] = [:]
        if fm.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppFailure(message: String(localized: "Ungültige Docker-Konfiguration."))
            }
            config = object
        }
        var dirs = config["cliPluginsExtraDirs"] as? [String] ?? []
        let plugins = DockerCLI.toolsDirectory.appendingPathComponent("cli-plugins").path
        if !dirs.contains(plugins) { dirs.append(plugins) }
        config["cliPluginsExtraDirs"] = dirs
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try installShellIntegration()
        _ = try await terminalCLI(["context", "use", name])
        try await loadTerminalContexts()
        terminalStatus = String(localized: "Terminal-Standard: ") + terminalContext
    }
}

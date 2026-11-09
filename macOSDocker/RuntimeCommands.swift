import Foundation
import AppKit

@MainActor
extension RuntimeManager {
    func openPort(_ port: DockerPort, scheme: String? = nil) async throws {
        guard running else { throw AppFailure(message: String(localized: "VM zuerst starten.")) }
        let health = try await control.request("GET", "/health", timeout: 5)
        let address = PublishedPortAddress.host(binding: port.IP ?? "", type: port.Type, port: port.PublicPort ?? 0, vmAddresses: vmIPAddresses, macAddress: macIPAddress, forwardedPorts: forwardedTCPPorts, nat: effectiveBridgeID.isEmpty, macIPv6Addresses: macIPv6Addresses, forwardedIPv6Ports: forwardedIPv6TCPPorts)
        let preferred = address == macIPAddress || address.map(macIPv6Addresses.contains) == true ? address : nil
        let url = try port.browserURL(health: health, scheme: scheme, preferredHost: preferred)
        guard NSWorkspace.shared.open(url) else { throw AppFailure(message: String(localized: "Browser konnte nicht geöffnet werden: ") + url.absoluteString) }
    }

    func prepareMacBinds(_ binds: [BindRequirement], automaticallyShare: Bool, generation: UUID? = nil) async throws -> [String] {
        await macBindQueue.acquire()
        defer { macBindQueue.release() }
        try Task.checkCancellation()
        if let generation { try validateMountGeneration(generation) }
        var required: [String: Bool] = [:]
        for bind in binds {
            if ["/var/run/docker.sock", "/run/docker.sock"].contains(bind.source) { continue }
            let supplied = URL(fileURLWithPath: bind.source).standardizedFileURL.path
            let mapped = settings.shares.sorted { $0.path.count > $1.path.count }.first { supplied == "/macos" + $0.path || supplied.hasPrefix("/macos" + $0.path + "/") }
            let source = mapped.map { $0.path + supplied.dropFirst(("/macos" + $0.path).count) } ?? supplied
            let registered = settings.shares.contains { source == $0.path || source.hasPrefix($0.path + "/") }
            guard registered || source.hasPrefix("/Users/") || source.hasPrefix("/Volumes/") else {
                if bind.source.hasPrefix("/Users/") || bind.source.hasPrefix("/Volumes/") {
                    throw AppFailure(message: String(localized: "Mac-Bind-Pfad verlässt /Users oder /Volumes."))
                }
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
                throw AppFailure(message: String(localized: "Mac-Bind fehlt: \(source). Bitte die Datei oder den Ordner zuerst auf dem Mac erstellen."))
            }
            let directory = isDirectory.boolValue ? source : URL(fileURLWithPath: source).deletingLastPathComponent().path
            required[directory] = (required[directory] ?? true) && bind.readOnly
        }
        var additions: [HostShare] = []
        for (path, readOnly) in required.sorted(by: { $0.key.count < $1.key.count }) {
            if let existing = settings.shares.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                if existing.readOnly && !readOnly { throw AppFailure(message: String(localized: "\(path) liegt in der schreibgeschützten Freigabe \(existing.path). Bind mit :ro verwenden oder die Freigaberechte bei gestoppter VM ändern.")) }
                continue
            }
            if let index = additions.firstIndex(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                additions[index].readOnly = additions[index].readOnly && readOnly
                continue
            }
            guard !settings.shares.contains(where: { $0.path.hasPrefix(path + "/") }) else {
                throw AppFailure(message: String(localized: "\(path) umfasst eine bereits freigegebene Unterstruktur. Bitte Freigaben bei gestoppter VM zusammenfassen."))
            }
            additions.append(HostShare(path: path, readOnly: readOnly, automatic: true))
        }
        if (!automaticallyShare || engineMaintenance || additions.contains(where: { !settings.automaticallySharesMacPath($0.path) })) && !additions.isEmpty {
            throw AppFailure(message: String(localized: "Fehlende Mac-Freigaben:\n") + additions.map(\.path).joined(separator: "\n") + String(localized: "\nAutomatische Freigabe aktivieren oder diese Ordner unter Mac-Freigaben hinzufügen."))
        }
        settings.shares += additions
        try await updateShares()
        return additions.map(\.path)
    }

    private func writeTerminalLauncher() throws -> URL {
        try DockerCLI.prepareConfiguration()
        let fm = FileManager.default
        let bin = Self.socketDirectory.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appendingPathComponent("docker")
        let helper = DockerCLI.toolsDirectory.appendingPathComponent("bin/macosdocker-cli")
        guard fm.isExecutableFile(atPath: helper.path) else { throw AppFailure(message: "Terminal-Mount-Client fehlt. App neu bauen.") }
        let text = "#!/bin/sh\nexec " + shellQuote(helper.path) + " " + shellQuote(terminalMountPath) + " " + shellQuote("unix://" + dockerPath) + " " + shellQuote(try DockerCLI.executable().path) + " \"$@\"\n"
        try text.write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return bin
    }

    func installShellIntegration(shellDirectory: URL? = nil) throws {
        let bin = try writeTerminalLauncher()
        let fm = FileManager.default
        let home = shellDirectory ?? ProcessInfo.processInfo.environment["ZDOTDIR"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
        let rc = home.appendingPathComponent(".zshrc").resolvingSymlinksInPath()
        let marker = "# macOSDocker bundled CLI"
        var content = fm.fileExists(atPath: rc.path) ? try String(contentsOf: rc, encoding: .utf8) : ""
        if !content.contains(marker) {
            content += "\n" + marker + "\nexport PATH=" + shellQuote(bin.path) + ":\"$PATH\"\n"
            try content.write(to: rc, atomically: true, encoding: .utf8)
        }
        terminalStatus = String(localized: "Mitgelieferte Docker CLI eingerichtet. Neues zsh-Terminal öffnen; der ausgewählte Docker-Context wird verwendet.")
    }

    func installTerminalContext(makeDefault: Bool) async throws {
        _ = try writeTerminalLauncher()
        let job = CLIProcess()
        let listed = try await job.run(arguments: ["context", "ls", "--format", "{{.Name}}"] ).checked()
        let exists = String(decoding: listed.stdout, as: UTF8.self).split(separator: "\n").contains("macosdocker")
        if exists {
            let data = try await job.run(arguments: ["context", "inspect", "macosdocker"]).checked()
            guard let contexts = try JSONSerialization.jsonObject(with: data.stdout) as? [[String: Any]],
                  let endpoints = contexts.first?["Endpoints"] as? [String: Any], let endpoint = endpoints["docker"] as? [String: Any],
                  endpoint["Host"] as? String == "unix://" + dockerPath else {
                throw AppFailure(message: String(localized: "Ein anderer Docker-Context namens macosdocker existiert bereits. Bitte diesen im Terminal umbenennen; er wird nicht überschrieben."))
            }
        } else {
            _ = try await job.run(arguments: ["context", "create", "macosdocker", "--description", "macOSDocker Linux runtime", "--docker", "host=unix://" + dockerPath]).checked()
        }
        if makeDefault {
            _ = try await job.run(arguments: ["context", "use", "macosdocker"]).checked()
            terminalStatus = String(localized: "macosdocker ist der Standard-Context. Im Terminal funktionieren jetzt docker run, docker ps und docker compose. Bereits gesetzte DOCKER_HOST-/DOCKER_CONTEXT-Variablen dort gegebenenfalls mit unset entfernen.")
        } else { terminalStatus = String(localized: "Context bereit: docker --context macosdocker run …") }
    }

    func openDockerTerminal(arguments: [String]? = nil, directory: URL? = nil) throws {
        try DockerCLI.prepareConfiguration()
        let docker = try DockerCLI.executable()
        let workingDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser
        try FileManager.default.createDirectory(at: Self.socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let command = Self.socketDirectory.appendingPathComponent("terminal-" + UUID().uuidString + ".command")
        let path = DockerCLI.environment(directory: workingDirectory)["PATH"] ?? "/usr/bin:/bin"
        var script = "#!/bin/zsh\nrm -- \"$0\"\ncd -- " + shellQuote(workingDirectory.path) + " || exit 1\n"
        script += "unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH\nexport DOCKER_HOST=" + shellQuote("unix://" + dockerPath) + "\nexport PATH=" + shellQuote(path) + "\n"
        script += "export DOCKER_CONFIG=" + shellQuote(DockerCLI.configurationDirectory.path) + "\n"
        if let arguments {
            script += ([docker.path, "--host", "unix://" + dockerPath] + arguments).map(shellQuote).joined(separator: " ") + "\n"
            script += "/usr/bin/printf '%s\\n' " + shellQuote(String(localized: "Docker-Befehl beendet. Dieses Terminal verwendet weiterhin macOSDocker.")) + "\n"
        } else { script += "/usr/bin/printf '%s\\n' " + shellQuote(String(localized: "macOSDocker-Terminal: docker run, docker compose, docker ps")) + "\n" }
        script += "exec /bin/zsh -f -i\n"
        try script.write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        NSWorkspace.shared.open(command)
    }
}

import Foundation
import Darwin

@main enum TerminalMountClient {
    static func main() {
        let input = Array(CommandLine.arguments.dropFirst())
        guard input.count >= 3 else { fputs("macOSDocker: ungültiger Terminal-Aufruf.\n", stderr); exit(2) }
        let socketPath = input[0]
        let expectedHost = input[1]
        let docker = input[2]
        let arguments = Array(input.dropFirst(3))
        if arguments.isEmpty || ProcessInfo.processInfo.environment["MACOSDOCKER_AUTO_SHARES"] == "0" { execute(docker, arguments) }
        var executionArguments = arguments
        do {
            let rootHelp = try capture(docker, ["--help"])
            guard let parsed = try? CLIOptions(help: rootHelp).parse(arguments) else { execute(docker, arguments) }
            let command = parsed.remainder
            let isRun = command.first == "run" || Array(command.prefix(2)) == ["container", "run"]
            if ProcessInfo.processInfo.environment["MACOSDOCKER_AUTO_SHARES"] != "0", (isRun || command.first == "compose"), try targetsRuntime(docker, options: parsed.options, expectedHost: expectedHost) {
                var binds: [BindRequirement] = []
                if isRun {
                    let help = try capture(docker, ["run", "--help"])
                    let words = command.first == "container" ? Array(command.dropFirst(2)) : Array(command.dropFirst())
                    guard let options = try? CLIOptions(help: help).parse(words) else { execute(docker, arguments) }
                    if !options.options.contains(where: { $0.0 == "help" }) {
                        let prepared = try DockerRunParser.prepare(arguments: ["docker"] + command, directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), help: help)
                        binds = prepared.binds
                        executionArguments = CLIOptions.arguments(parsed.options) + prepared.arguments
                    }
                } else {
                    let globals = CLIOptions.arguments(parsed.options)
                    let help = try capture(docker, globals + ["compose", "--help"])
                    guard let options = try? CLIOptions(help: help).parse(Array(command.dropFirst())) else { execute(docker, arguments) }
                    if let action = options.remainder.first, ["up", "run", "create", "start"].contains(action) {
                        guard !options.options.contains(where: { $0.0 == "file" && $0.1 == "-" }) else { throw AppFailure(message: "Automatische Mac-Freigaben benötigen eine Compose-Datei. Für stdin bitte vorher die Freigaben einrichten und MACOSDOCKER_AUTO_SHARES=0 verwenden.") }
                        let actionHelp = try capture(docker, globals + ["compose", action, "--help"])
                        let actionOptions = try CLIOptions(help: help + "\n" + actionHelp).parse(Array(options.remainder.dropFirst()))
                        let globalNames = Set(CLIOptions(help: help).definitions.values.map { $0.long })
                        let composeOptions = options.options + actionOptions.options.filter { globalNames.contains($0.0) }
                        guard !composeOptions.contains(where: { $0.0 == "file" && $0.1 == "-" }) else { throw AppFailure(message: "Für Compose über stdin bitte vorher die Freigaben einrichten und MACOSDOCKER_AUTO_SHARES=0 verwenden.") }
                        let model = try capture(docker, globals + ["compose"] + CLIOptions.arguments(composeOptions) + ["config", "--format", "json"])
                        binds = try composeBinds(Data(model.utf8))
                    }
                }
                binds = binds.filter { $0.source.hasPrefix("/") }
                if !binds.isEmpty { try prepare(binds, socketPath: socketPath) }
            }
        } catch {
            fputs("macOSDocker: " + error.localizedDescription + "\n", stderr)
            exit(1)
        }
        execute(docker, executionArguments)
    }

    private static func execute(_ docker: String, _ arguments: [String]) -> Never {
        let argv = ([docker] + arguments).map { strdup($0) } + [nil]
        argv.withUnsafeBufferPointer { _ = execv(docker, $0.baseAddress!) }
        fputs("macOSDocker: Docker CLI konnte nicht gestartet werden.\n", stderr)
        exit(127)
    }

    private static func capture(_ docker: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        var data = Data()
        while let part = try pipe.fileHandleForReading.read(upToCount: 65536), !part.isEmpty {
            data.append(part)
            if data.count > 16 * 1024 * 1024 {
                process.terminate()
                process.waitUntilExit()
                throw AppFailure(message: "Docker-Konfiguration ist zu gross.")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppFailure(message: "Docker-Konfiguration konnte nicht geprüft werden.") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func targetsRuntime(_ docker: String, options: [(String, String?)], expectedHost: String) throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let host = options.last(where: { $0.0 == "host" })?.1
        let context = options.last(where: { $0.0 == "context" })?.1
        let selected: String
        if let host { selected = host }
        else if let context = context ?? environment["DOCKER_CONTEXT"], !context.isEmpty {
            let config = CLIOptions.arguments(options.filter { $0.0 == "config" })
            selected = try capture(docker, config + ["context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let host = environment["DOCKER_HOST"], !host.isEmpty { selected = host }
        else {
            let config = CLIOptions.arguments(options.filter { $0.0 == "config" })
            selected = try capture(docker, config + ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard selected.hasPrefix("unix://"), expectedHost.hasPrefix("unix://") else { return false }
        return URL(fileURLWithPath: String(selected.dropFirst(7))).resolvingSymlinksInPath() == URL(fileURLWithPath: String(expectedHost.dropFirst(7))).resolvingSymlinksInPath()
    }

    private static func composeBinds(_ data: Data) throws -> [BindRequirement] {
        guard let model = try JSONSerialization.jsonObject(with: data) as? [String: Any], let services = model["services"] as? [String: [String: Any]] else { throw AppFailure(message: "Ungültige Compose-Konfiguration.") }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var binds: [BindRequirement] = []
        for service in services.values {
            for mount in service["volumes"] as? [[String: Any]] ?? [] where mount["type"] as? String == "bind" {
                if let path = mount["source"] as? String { binds.append(BindRequirement(source: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL.path, readOnly: mount["read_only"] as? Bool ?? false)) }
            }
        }
        for category in ["secrets", "configs"] {
            let used = Set(services.values.flatMap { ($0[category] as? [[String: Any]] ?? []).compactMap { $0["source"] as? String } })
            let definitions = model[category] as? [String: [String: Any]] ?? [:]
            for name in used {
                if let path = definitions[name]?["file"] as? String { binds.append(BindRequirement(source: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL.path, readOnly: true)) }
            }
        }
        return binds
    }

    private static func prepare(_ binds: [BindRequirement], socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppFailure(message: "Terminal-Mount-Socket konnte nicht erstellt werden.") }
        defer { Darwin.close(fd) }
        TerminalMountIO.configure(fd, seconds: 120)
        var address = try TerminalMountIO.address(socketPath)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard connected == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw AppFailure(message: "macOSDocker zuerst starten und warten, bis die VM bereit ist.") }
        try TerminalMountIO.write(TerminalMountRequest(binds: binds), to: fd)
        let reply = try TerminalMountIO.read(TerminalMountReply.self, from: fd)
        guard reply.success else { throw AppFailure(message: reply.error ?? "Mac-Freigaben konnten nicht eingerichtet werden.") }
    }
}

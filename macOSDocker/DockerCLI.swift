import Foundation
import Darwin

struct CLIResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let combined: Data
    let truncated: Bool
    var text: String { String(decoding: combined, as: UTF8.self) }
    func checked() throws -> Self {
        guard status == 0 else { throw AppFailure(message: String(localized: "Docker CLI (Exit \(status)):\n") + text) }
        return self
    }
}

enum DockerCLI {
    private static let configurationLock = NSLock()
    static var toolsDirectory: URL {
        Bundle.main.resourceURL!.appendingPathComponent("DockerTools")
    }
    static var configurationDirectory: URL {
        if let test = ProcessInfo.processInfo.environment["MACOSDOCKER_CLI_CONFIG"] { return URL(fileURLWithPath: test) }
        return RuntimeSettings.directory.appendingPathComponent("docker-config")
    }
    static func executable() throws -> URL {
        let executable = toolsDirectory.appendingPathComponent("bin/docker")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppFailure(message: String(localized: "Die mitgelieferte Docker CLI fehlt. Bitte die vollständige macOSDocker-App verwenden."))
        }
        return executable
    }
    static func prepareConfiguration() throws {
        configurationLock.lock(); defer { configurationLock.unlock() }
        let fm = FileManager.default
        let config = configurationDirectory
        try fm.createDirectory(at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plugins = config.appendingPathComponent("cli-plugins")
        try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
        for name in ["docker-compose", "docker-buildx"] {
            let source = toolsDirectory.appendingPathComponent("cli-plugins/" + name)
            guard fm.isExecutableFile(atPath: source.path) else { throw AppFailure(message: String(localized: "Mitgeliefertes Werkzeug fehlt: ") + name) }
            let target = plugins.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: target.path)) == source.path { continue }
            if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil || fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }
    static func environment(directory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION", "DOCKER_CLI_PLUGIN_EXTRA_DIRS", "BUILDX_BUILDER", "BUILDX_CONFIG", "BUILDKIT_HOST"] { environment.removeValue(forKey: key) }
        environment["DOCKER_CONFIG"] = configurationDirectory.path
        environment["PATH"] = toolsDirectory.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PWD"] = directory.path
        environment["COMPOSE_ANSI"] = "never"
        environment["COMPOSE_MENU"] = "false"
        return environment
    }
}

final class CLIProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true
        let active = process
        lock.unlock()
        if let active, active.isRunning {
            active.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self, active] in
                lock.lock(); defer { lock.unlock() }
                if process === active, active.isRunning { Darwin.kill(active.processIdentifier, SIGKILL) }
            }
        }
    }

    func run(arguments: [String], host: String? = nil, buildxDirectory: URL? = nil, directory: URL = FileManager.default.homeDirectoryForCurrentUser,
             onOutput: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> CLIResult {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try runBlocking(arguments: arguments, host: host, buildxDirectory: buildxDirectory, directory: directory, onOutput: onOutput)
            }.value
        } onCancel: { self.cancel() }
    }
    private func runBlocking(arguments: [String], host: String?, buildxDirectory: URL?, directory: URL, onOutput: @escaping @Sendable (Data) -> Void) throws -> CLIResult {
                try DockerCLI.prepareConfiguration()
                let command = Process()
                command.executableURL = try DockerCLI.executable()
                command.arguments = (host.map { ["--host", $0] } ?? []) + arguments
                command.currentDirectoryURL = directory
                var environment = DockerCLI.environment(directory: directory)
                if let host { environment["DOCKER_HOST"] = host }
                if let buildxDirectory { environment["BUILDX_CONFIG"] = buildxDirectory.path }
                command.environment = environment
                command.standardInput = FileHandle.nullDevice
                let stdout = Pipe(), stderr = Pipe()
                command.standardOutput = stdout; command.standardError = stderr
                lock.lock()
                if cancelled { lock.unlock(); throw CancellationError() }
                process = command
                do { try command.run() } catch { process = nil; lock.unlock(); throw error }
                lock.unlock()
                let capture = CLICapture()
                let drains = DispatchGroup()
                for (pipe, isError) in [(stdout, false), (stderr, true)] {
                    drains.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { drains.leave() }
                        while let data = try? pipe.fileHandleForReading.read(upToCount: 16384), !data.isEmpty {
                            capture.append(data, isError: isError)
                            onOutput(data)
                        }
                        try? pipe.fileHandleForReading.close()
                    }
                }
                command.waitUntilExit()
                drains.wait()
                lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
                if wasCancelled { throw CancellationError() }
                return capture.result(status: command.terminationStatus)
    }

}

private final class CLICapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data(), combined = Data()
    private var truncated = false
    private let limit = 16 * 1024 * 1024
    func append(_ data: Data, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isError { stderr.append(data) } else { stdout.append(data) }
        combined.append(data)
        if stdout.count > limit { stdout = Data(stdout.suffix(limit)); truncated = true }
        if stderr.count > limit { stderr = Data(stderr.suffix(limit)); truncated = true }
        if combined.count > limit { combined = Data(combined.suffix(limit)); truncated = true }
    }
    func result(status: Int32) -> CLIResult {
        lock.lock(); defer { lock.unlock() }
        return CLIResult(status: status, stdout: stdout, stderr: stderr, combined: combined, truncated: truncated)
    }
}

import Foundation
import Combine

struct HistoryBuilder: Identifiable, Equatable {
    let id: String
    let name: String
    let containerID: String?
    static let engine = Self(id: "default", name: "Docker Engine", containerID: nil)
}

@MainActor
final class BuildHistoryController: ObservableObject {
    @Published var records: [BuildRecord] = []
    @Published var problem: String?
    @Published var loading = false
    @Published var showingDetails = false
    @Published private(set) var deleting = false
    private var mutationRevision = 0
    private var configured = Set<String>()
    private var generation = UUID()
    private var displayedBuilder: String?
    private let directory = RuntimeSettings.directory.appendingPathComponent("build-history-buildx")

    private func run(_ arguments: [String], host: String) async throws -> CLIResult {
        let job = CLIProcess()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)); job.cancel() } catch { }
        }
        defer { timeout.cancel() }
        let result = try await job.run(arguments: ["buildx"] + arguments, host: host, buildxDirectory: directory)
        try Task.checkCancellation()
        return try result.checked()
    }

    private func builderName(_ builder: HistoryBuilder, host: String) async throws -> String {
        guard let containerID = builder.containerID else { return "default" }
        let name = "observer-" + containerID
        if !configured.contains(containerID) {
            let existing = try await run(["ls", "--format", "{{.Name}}"], host: host)
            if !String(decoding: existing.stdout, as: UTF8.self).split(separator: "\n").contains(Substring(name)) {
                _ = try await run(["create", "--name", name, "--driver", "remote", "docker-container://" + containerID], host: host)
            }
            configured.insert(containerID)
        }
        return name
    }

    func watch(_ builder: HistoryBuilder, host: String) async {
        let token = UUID()
        generation = token
        if displayedBuilder != builder.id { records = [] }
        displayedBuilder = builder.id
        problem = nil
        loading = true
        defer { if generation == token { loading = false } }
        while !Task.isCancelled {
            if deleting {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                continue
            }
            let revision = mutationRevision
            do {
                let name = try await builderName(builder, host: host)
                let result = try await run(["history", "ls", "--builder", name, "--format", "json", "--no-trunc"], host: host)
                guard !result.truncated else { throw AppFailure(message: String(localized: "Build-Verlauf ist zu groß für die Anzeige.")) }
                let incoming = try BuildRecord.decode(result.stdout)
                try Task.checkCancellation()
                guard generation == token else { return }
                guard revision == mutationRevision else { continue }
                let byID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let known = Set(records.map(\.id))
                records = records.compactMap { byID[$0.id] } + incoming.filter { !known.contains($0.id) }.sorted {
                    ($0.created_at ?? "", $0.id) > ($1.created_at ?? "", $1.id)
                }
                problem = nil
            } catch {
                if generation != token { return }
                if Task.isCancelled { loading = false; return }
                problem = error is CancellationError ? String(localized: "Zeitüberschreitung beim Lesen des Build-Verlaufs.") : error.localizedDescription
            }
            loading = false
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func remove(_ record: BuildRecord, builder: HistoryBuilder, host: String) async throws {
        guard !deleting, record.status.lowercased() != "running" else { return }
        deleting = true
        mutationRevision += 1
        defer { deleting = false; mutationRevision += 1 }
        let name = try await builderName(builder, host: host)
        _ = try await run(["history", "rm", "--builder", name, "--", record.recordID], host: host)
        if displayedBuilder == builder.id { records.removeAll { $0.id == record.id } }
    }

    func details(_ record: BuildRecord, builder: HistoryBuilder, host: String, logs: Bool) async throws -> String {
        showingDetails = true
        defer { showingDetails = false }
        let name = try await builderName(builder, host: host)
        let args = logs ? ["history", "logs", "--progress", "plain"] : ["history", "inspect", "--format", "json"]
        let result = try await run(args + ["--builder", name, record.recordID], host: host)
        return result.text + (result.truncated ? "\n" + String(localized: "Ausgabe gekürzt.") : "")
    }
}

import SwiftUI

struct BuildHistoryView: View {
    @EnvironmentObject var runtime: RuntimeManager
    @StateObject private var history = BuildHistoryController()
    private struct PendingDeletion {
        let record: BuildRecord
        let builder: HistoryBuilder
        let host: String
    }
    @State private var pendingDeletion: PendingDeletion?
    @State private var selected = "default"
    @State private var refreshID = UUID()
    @State private var detailTask: Task<Void, Never>?

    private var builders: [HistoryBuilder] {
        [.engine] + runtime.containers.filter { $0.State == "running" && $0.name.hasPrefix("buildx_buildkit_") }
            .sorted { $0.name < $1.name }
            .map { HistoryBuilder(id: $0.id, name: $0.name, containerID: $0.id) }
    }
    private var builder: HistoryBuilder { builders.first { $0.id == selected } ?? .engine }
    private var host: String { "unix://" + runtime.dockerPath }

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker(String(localized: "Builder"), selection: $selected) {
                        ForEach(builders) { item in Text(item.name).tag(item.id) }
                    }
                    ProgressView().controlSize(.small)
                        .opacity(history.loading || history.deleting ? 1 : 0)
                        .accessibilityHidden(!history.loading && !history.deleting)
                    Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                        .help(String(localized: "Aktualisieren"))
                }
                Text(String(localized: "Buildx-Verlauf dieses Builders, auch für Builds aus dem Terminal. Automatische Aktualisierung alle 5 Sekunden."))
                    .font(.caption).foregroundStyle(.secondary)
                if runtime.canQueryDocker, let problem = history.problem {
                    Text(String(localized: "Build-Verlauf nicht verfügbar. Der Builder muss Buildx History unterstützen."))
                        .font(.caption).foregroundStyle(.orange)
                    Text(problem).font(.caption).textSelection(.enabled)
                }
                if history.records.isEmpty && !history.loading && history.problem == nil {
                    Text(String(localized: "Noch keine gespeicherten Builds."))
                        .foregroundStyle(.secondary).padding(.vertical)
                }
                ForEach(history.records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.name.isEmpty ? record.recordID : record.name).font(.headline)
                            Spacer()
                            Text(status(record.status)).foregroundStyle(.secondary)
                        }
                        HStack {
                            if let date = record.createdDate { Text(date, format: .dateTime.day().month().hour().minute()) }
                            if let duration = record.duration { Text(duration) }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(record.recordID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button(String(localized: "Details")) { show(record, logs: false) }
                            Button(String(localized: "Logs")) { show(record, logs: true) }
                            Button(role: .destructive) {
                                pendingDeletion = PendingDeletion(record: record, builder: builder, host: host)
                            } label: { Image(systemName: "trash") }
                            .help(String(localized: "Build-Verlauf löschen"))
                            .disabled(record.status.lowercased() == "running" || runtime.busy || runtime.commandRunning || runtime.engineMaintenance)
                        }.disabled(history.showingDetails || history.deleting)
                    }.padding(.vertical, 4)
                }
                Text(String(localized: "Zusätzliche Builder erscheinen, solange ihre BuildKit-Container in dieser VM laufen. Gelöschte Build-Verläufe und externe Remote-Builder sind nicht enthalten."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .disabled(!runtime.canQueryDocker)
        .task(id: builder.id + refreshID.uuidString + String(runtime.canQueryDocker)) {
            guard runtime.canQueryDocker else { return }
            await history.watch(builder, host: host)
        }
        .onChange(of: runtime.canQueryDocker) { _, available in
            if !available { detailTask?.cancel() }
        }
        .onChange(of: builders.map(\.id)) { _, ids in
            if !ids.contains(selected) { selected = "default" }
        }
        .onChange(of: selected) { _, _ in detailTask?.cancel() }
        .onDisappear { detailTask?.cancel() }
        .confirmationDialog(String(localized: "Build-Verlauf löschen?"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button(String(localized: "Löschen"), role: .destructive) {
                guard let target = pendingDeletion else { return }
                pendingDeletion = nil
                runtime.perform {
                    guard !runtime.busy, !runtime.commandRunning, !runtime.engineMaintenance else { return }
                    runtime.busy = true
                    defer { runtime.busy = false; refreshID = UUID() }
                    try await history.remove(target.record, builder: target.builder, host: target.host)
                }
            }
        } message: {
            Text(String(localized: "Der ausgewählte Build-Eintrag und seine gespeicherten Logs werden gelöscht. Images und Container bleiben erhalten."))
        }
    }

    private func show(_ record: BuildRecord, logs: Bool) {
        let target = builder
        detailTask?.cancel()
        detailTask = Task {
            do {
                let output = try await history.details(record, builder: target, host: host, logs: logs)
                try Task.checkCancellation()
                guard runtime.canQueryDocker else { return }
                runtime.details = output
            } catch {
                if !Task.isCancelled && runtime.canQueryDocker { runtime.error = error.localizedDescription }
            }
        }
    }
    private func status(_ value: String) -> String {
        switch value.lowercased() {
        case "completed": String(localized: "Abgeschlossen")
        case "running": String(localized: "Läuft")
        case "error", "failed": String(localized: "Fehlgeschlagen")
        case "canceled", "cancelled": String(localized: "Abgebrochen")
        default: value
        }
    }
}

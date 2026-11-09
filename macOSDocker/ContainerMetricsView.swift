import SwiftUI
import Charts

struct ContainerMetricsView: View {
    @EnvironmentObject var runtime: RuntimeManager
    let containerID: String
    @State private var samples: [Sample] = []
    @State private var latest: ContainerMetrics?
    @State private var unavailable = false
    private struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        let values: [Double?]
    }
    private var enabled: Bool {
        runtime.dashboardVisible && runtime.running && runtime.containers.contains { $0.id == containerID && $0.State == "running" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(runtime.containers.first { $0.id == containerID }?.name ?? String(containerID.prefix(12))).font(.subheadline.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metric("CPU", indices: [0], labels: ["CPU"], unit: "%")
                metric("RAM", indices: [1], labels: ["RAM"], unit: "MB")
                metric(String(localized: "Netzwerk"), indices: [2, 3], labels: ["↓", "↑"], unit: "MB/s")
                metric("Disk I/O", indices: [4, 5], labels: [String(localized: "Lesen"), String(localized: "Schreiben")], unit: "MB/s")
            }
            if let limit = latest?.limit, limit > 0 {
                Text(String(localized: "RAM-Limit: ") + String(format: "%.2f GiB", limit / 1_073_741_824)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(containerID)-\(enabled)") {
            samples = []; latest = nil; unavailable = false
            guard enabled else { return }
            var previous: ContainerMetrics?
            while !Task.isCancelled {
                do {
                    let data = try await runtime.api.request("GET", "/containers/\(containerID)/stats?stream=false&one-shot=true", timeout: 3)
                    try Task.checkCancellation()
                    let snapshot = try ContainerMetrics(data: data)
                    samples.append(Sample(time: snapshot.time, values: snapshot.rates(since: previous)))
                    samples.removeAll { $0.time < snapshot.time.addingTimeInterval(-60) }
                    latest = snapshot; previous = snapshot; unavailable = false
                } catch {
                    if Task.isCancelled { return }
                    unavailable = true; previous = nil
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func pendingText(for index: Int) -> String {
        guard enabled, !unavailable else { return String(localized: "Nicht verfügbar") }
        guard let latest else { return String(localized: "Lädt …") }
        let counters = [latest.cpu, latest.memory, latest.rx, latest.tx, latest.read, latest.write]
        guard counters[index] != nil, index != 0 || latest.system != nil else {
            return String(localized: "Nicht verfügbar")
        }
        return String(localized: "Misst …")
    }
    private func metric(_ title: String, indices: [Int], labels: [String], unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                let value = enabled && !unavailable ? samples.last?.values[index] : nil
                Text(labels[offset] + ": " + (value.map { String(format: "%.1f %@", index == 0 ? $0 : $0 / 1_000_000, unit) } ?? pendingText(for: index)))
                    .font(.caption2).monospacedDigit()
            }
            Chart {
                ForEach(samples) { sample in
                    ForEach(Array(indices.enumerated()), id: \.element) { offset, index in
                        if let value = sample.values[index] {
                            LineMark(x: .value("Time", sample.time), y: .value("Value", value))
                                .foregroundStyle(by: .value("Series", labels[offset]))
                        }
                    }
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXScale(domain: (samples.last?.time ?? Date()).addingTimeInterval(-60)...(samples.last?.time ?? Date()))
            .frame(height: 40)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

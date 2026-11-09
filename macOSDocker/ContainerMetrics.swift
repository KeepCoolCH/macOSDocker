import Foundation

struct ContainerMetrics {
    let time: Date
    let cpu: Double?
    let system: Double?
    let cores: Double
    let memory: Double?
    let limit: Double?
    let rx: Double?
    let tx: Double?
    let read: Double?
    let write: Double?

    init(data: Data, time: Date = Date()) throws {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        self.time = time
        let cpuStats = root["cpu_stats"] as? [String: Any] ?? [:]
        let usage = cpuStats["cpu_usage"] as? [String: Any] ?? [:]
        cpu = (usage["total_usage"] as? NSNumber)?.doubleValue
        system = (cpuStats["system_cpu_usage"] as? NSNumber)?.doubleValue
        cores = (cpuStats["online_cpus"] as? NSNumber)?.doubleValue ?? 1
        let mem = root["memory_stats"] as? [String: Any] ?? [:]
        let stats = mem["stats"] as? [String: Any] ?? [:]
        let cache = (stats["total_inactive_file"] as? NSNumber)?.doubleValue ?? (stats["inactive_file"] as? NSNumber)?.doubleValue ?? 0
        memory = (mem["usage"] as? NSNumber).map { max(0, $0.doubleValue - cache) }
        limit = (mem["limit"] as? NSNumber)?.doubleValue
        let networks = root["networks"] as? [String: [String: Any]]
        func network(_ key: String) -> Double? {
            guard let networks, !networks.isEmpty else { return nil }
            let values = networks.values.compactMap { ($0[key] as? NSNumber)?.doubleValue }
            return values.count == networks.count ? values.reduce(0, +) : nil
        }
        rx = network("rx_bytes"); tx = network("tx_bytes")
        let block = root["blkio_stats"] as? [String: Any]
        let entries = block?["io_service_bytes_recursive"] as? [[String: Any]]
        func disk(_ operation: String) -> Double? {
            guard let entries else { return nil }
            return entries.filter { ($0["op"] as? String)?.lowercased() == operation }
                .compactMap { ($0["value"] as? NSNumber)?.doubleValue }.reduce(0, +)
        }
        read = disk("read"); write = disk("write")
    }
    func rates(since old: Self?) -> [Double?] {
        guard let old, time > old.time else { return [nil, memory, nil, nil, nil, nil] }
        let seconds = time.timeIntervalSince(old.time)
        func delta(_ value: Double?, _ previous: Double?) -> Double? {
            guard let value, let previous, value >= previous else { return nil }
            return value - previous
        }
        let cpuPercent: Double?
        if let used = delta(cpu, old.cpu), let total = delta(system, old.system), total > 0 {
            cpuPercent = used / total * cores * 100
        } else { cpuPercent = nil }
        return [cpuPercent, memory, delta(rx, old.rx).map { $0 / seconds }, delta(tx, old.tx).map { $0 / seconds },
                delta(read, old.read).map { $0 / seconds }, delta(write, old.write).map { $0 / seconds }]
    }
}

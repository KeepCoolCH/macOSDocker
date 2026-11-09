import Foundation
import Darwin

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct HostShare: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var readOnly = false
    var automatic: Bool? = nil
    var key: String { "share" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

enum RuntimeDefaults {
    static var maximumCPUCount: Int { max(1, ProcessInfo.processInfo.processorCount) }
    static var maximumMemoryGiB: Int { max(1, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))) }

    static func cpuCount(available: Int) -> Int {
        min(max(1, available), max(2, ((max(1, available) + 3) / 4) * 2))
    }

    static func memoryGiB(physicalMemory: UInt64) -> Int {
        max(1, Int(physicalMemory / (4 * 1024 * 1024 * 1024)))
    }
}

struct RuntimeSettings: Codable {
    var cpus = RuntimeDefaults.cpuCount(available: ProcessInfo.processInfo.processorCount)
    var memoryGiB = RuntimeDefaults.memoryGiB(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    var dataGiB = 64
    var bridgeID = ""
    var network: VMNetworkSettings?
    var ipv6ForNewContainers: Bool? = nil
    var createsIPv6Containers: Bool {
        get { ipv6ForNewContainers ?? false }
        set { ipv6ForNewContainers = newValue }
    }
    var networkConfiguration: VMNetworkSettings {
        get { network ?? VMNetworkSettings() }
        set { network = newValue }
    }
    var automaticSMBVolumes: [String]?
    var automaticMacPaths: Bool? = nil
    var automaticUsersPaths: Bool? = nil
    var automaticVolumesPaths: Bool? = nil
    var automaticallyShareUsersPaths: Bool { automaticUsersPaths ?? automaticMacPaths ?? true }
    var automaticallyShareVolumesPaths: Bool { automaticVolumesPaths ?? automaticMacPaths ?? true }
    var automaticallyShareMacPaths: Bool {
        get { automaticallyShareUsersPaths && automaticallyShareVolumesPaths }
        set {
            automaticMacPaths = newValue
            automaticUsersPaths = newValue
            automaticVolumesPaths = newValue
        }
    }
    func automaticallySharesMacPath(_ path: String) -> Bool {
        (path.hasPrefix("/Users/") && automaticallyShareUsersPaths) || (path.hasPrefix("/Volumes/") && automaticallyShareVolumesPaths)
    }
    mutating func setAutomaticSharing(_ enabled: Bool, root: String) {
        guard ["/Users", "/Volumes"].contains(root) else { return }
        let users = root == "/Users" ? enabled : automaticallyShareUsersPaths
        let volumes = root == "/Volumes" ? enabled : automaticallyShareVolumesPaths
        automaticUsersPaths = users
        automaticVolumesPaths = volumes
        automaticMacPaths = users && volumes
        shares = shares.filter { $0.automatic != true || automaticallySharesMacPath($0.path) }
    }
    var shares: [HostShare] = []
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["MACOSDOCKER_HOME"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/macOSDocker", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("settings.json") }
    mutating func limitResources(maximumCPUs: Int = RuntimeDefaults.maximumCPUCount, maximumMemoryGiB: Int = RuntimeDefaults.maximumMemoryGiB) {
        cpus = min(max(1, cpus), max(1, maximumCPUs))
        memoryGiB = min(max(1, memoryGiB), max(1, maximumMemoryGiB))
    }

    static func load() -> Self {
        var settings = (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: file))) ?? Self()
        settings.limitResources()
        settings.shares = settings.shares.filter { $0.automatic != true || settings.automaticallySharesMacPath($0.path) }
        return settings
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
    }
}

struct ContainerMount: Decodable {
    let Source: String?
    let Destination: String
}

struct DockerContainer: Decodable, Identifiable {
    let Id: String
    let Names: [String]
    let Image: String
    let State: String
    let Status: String
    let Ports: [DockerPort]?
    var Mounts: [ContainerMount]? = nil
    var Labels: [String: String]? = nil
    var id: String { Id }
    var name: String { Names.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? String(Id.prefix(12)) }
}
struct DockerImage: Decodable, Identifiable {
    let Id: String
    let RepoTags: [String]?
    let Size: Int64
    var id: String { Id }
    var name: String { RepoTags?.first ?? String(Id.prefix(24)) }
}
struct DockerVolume: Decodable, Identifiable {
    let Name: String
    let Driver: String
    let Mountpoint: String
    var id: String { Name }
}
struct VolumeList: Decodable { let Volumes: [DockerVolume]? }
struct DockerNetwork: Decodable, Identifiable {
    let Id: String
    let Name: String
    let Driver: String
    var id: String { Id }
}

func prettyJSON(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else {
        return String(decoding: data, as: UTF8.self)
    }
    return String(decoding: formatted, as: UTF8.self)
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

struct DockerPort: Decodable, Hashable, Identifiable {
    var id: String { "\(IP ?? "")|\(PublicPort ?? 0)|\(PrivatePort)|\(Type)" }
    static func publishedTCP(_ ports: [Self]) -> [Self] {
        Array(Set(ports.filter { $0.Type == "tcp" && ($0.PublicPort ?? 0) > 0 })).sorted {
            ($0.PublicPort ?? 0, $0.PrivatePort, $0.IP ?? "") < ($1.PublicPort ?? 0, $1.PrivatePort, $1.IP ?? "")
        }
    }
    let IP: String?
    let PrivatePort: Int
    let PublicPort: Int?
    let `Type`: String
    var browserCapable: Bool { Type == "tcp" && PublicPort != nil && !(IP ?? "").hasPrefix("127.") && (IP ?? "") != "::1" }
    var label: String {
        guard let PublicPort else { return String(localized: "\(PrivatePort)/\(Type) · intern") }
        let binding = ((IP ?? "").isEmpty || IP == "0.0.0.0" ? "" : "\(IP!) · ")
        return "\(binding)\(PublicPort) → \(PrivatePort)/\(Type)"
    }
    func browserURL(health: Data, scheme: String? = nil, preferredHost: String? = nil) throws -> URL {
        guard browserCapable, let PublicPort else { throw AppFailure(message: String(localized: "Dieser Port ist nicht als TCP-Port für den Mac erreichbar. Nur veröffentlichte Ports öffnen; Loopback-Bindings gelten innerhalb der VM.")) }
        let root = try JSONSerialization.jsonObject(with: health) as? [String: Any]
        let interfaces = root?["addresses"] as? [[String: Any]] ?? []
        let addresses = interfaces.filter { $0["ifname"] as? String == "eth0" }.flatMap { $0["addr_info"] as? [[String: Any]] ?? [] }
        let binding = IP ?? ""
        let host: String
        if let preferredHost {
            host = preferredHost
        } else if binding.isEmpty || binding == "0.0.0.0" || binding == "::" {
            guard let address = addresses.first(where: { ($0["family"] as? String == (binding == "::" ? "inet6" : "inet")) && $0["scope"] as? String == "global" }), let local = address["local"] as? String else {
                throw AppFailure(message: binding == "::" ? String(localized: "Die VM hat noch keine IPv6-Adresse. Unter Runtime die Netzwerkverbindung prüfen.") : String(localized: "Die VM hat noch keine IPv4-Adresse. Unter Runtime die Netzwerkverbindung prüfen."))
            }
            host = local
        } else { host = binding }
        var components = URLComponents()
        components.scheme = scheme ?? (PrivatePort == 443 || PublicPort == 443 ? "https" : "http")
        let endpoint = preferredHost ?? host
        components.host = endpoint.contains(":") && !endpoint.hasPrefix("[") ? "[" + endpoint + "]" : endpoint
        components.port = PublicPort
        guard let url = components.url else { throw AppFailure(message: String(localized: "Ungültige Port-Adresse.")) }
        return url
    }
}

enum VMIPv4Mode: String, CaseIterable, Identifiable, Codable {
    case automatic, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatisch (DHCP)")
        case .manual: String(localized: "Manuell")
        }
    }
}

enum VMIPv6Mode: String, CaseIterable, Identifiable, Codable {
    case disabled, automatic, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: String(localized: "Deaktiviert")
        case .automatic: String(localized: "Automatisch (SLAAC)")
        case .manual: String(localized: "Manuell")
        }
    }
}

struct VMIPv6Settings: Codable {
    var mode = VMIPv6Mode.disabled
    var address = ""
    var prefix = 64
    var gateway = ""
    var dns = ""
    func payload() throws -> [String: Any] {
        guard mode == .manual else { return ["mode": mode.rawValue] }
        func valid(_ value: String) -> Bool {
            var address = in6_addr()
            return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        let ip = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let router = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        let servers = dns.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard valid(ip), (1...128).contains(prefix), router.isEmpty || valid(router), servers.count <= 3, servers.allSatisfy(valid) else {
            throw AppFailure(message: String(localized: "Gültige IPv6-Adresse, Präfix 1–128 und optional Gateway/DNS als IPv6 eingeben."))
        }
        return ["mode": mode.rawValue, "address": ip, "prefix": prefix, "gateway": router, "dns": servers]
    }
}

struct VMNetworkSettings: Codable {
    var ipv6: VMIPv6Settings?
    var ipv6Configuration: VMIPv6Settings {
        get { ipv6 ?? VMIPv6Settings() }
        set { ipv6 = newValue }
    }
    var address = ""
    var prefix = 24
    var gateway = ""
    var dns = ""
    var ipv4Mode: VMIPv4Mode?
    var ipv4ConfigurationMode: VMIPv4Mode {
        get { ipv4Mode ?? (address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .automatic : .manual) }
        set { ipv4Mode = newValue }
    }
    var automatic: Bool { ipv4ConfigurationMode == .automatic }
    mutating func suggestIPv4Gateway() {
        guard !automatic, gateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...30).contains(prefix) else { return }
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return }
        var octets: [UInt32] = []
        for part in parts {
            guard let value = UInt32(part), value < 256, String(value) == part else { return }
            octets.append(value)
        }
        let ip = octets.reduce(UInt32(0)) { ($0 << 8) | $1 }
        let candidate = (ip & 0xffffff00) | 1
        let mask = UInt32.max << (32 - prefix)
        let network = ip & mask
        guard candidate != ip, candidate & mask == network, candidate > network, candidate < network | ~mask else { return }
        gateway = octets.prefix(3).map(String.init).joined(separator: ".") + ".1"
    }
    func payload() throws -> Data {
        if automatic { return try JSONSerialization.data(withJSONObject: ["mode": "dhcp", "ipv6": try ipv6Configuration.payload()]) }
        func ipv4(_ text: String) -> Bool {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy { part in
                guard let value = Int(part), (0...255).contains(value) else { return false }
                return String(value) == part
            }
        }
        let ip = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let router = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        let servers = dns.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard ipv4(ip), (1...30).contains(prefix), router.isEmpty || ipv4(router), servers.allSatisfy(ipv4) else {
            throw AppFailure(message: String(localized: "Gültige IPv4-Adresse, Präfix 1–30 und optional Gateway/DNS als IPv4 eingeben."))
        }
        return try JSONSerialization.data(withJSONObject: ["mode": "static", "address": ip, "prefix": prefix, "gateway": router, "dns": servers, "ipv6": try ipv6Configuration.payload()])
    }
}

import Foundation
import Darwin

enum NetworkDriver: String, CaseIterable, Identifiable {
    case bridge, macvlan, ipvlan
    var id: String { rawValue }
}

struct NetworkCreation {
    var driver = NetworkDriver.bridge
    var subnet = ""
    var gateway = ""
    var ipRange = ""
    var parent = "eth0"
    var ipvlanMode = "l2"
    var internalOnly = false
    var ipv6Enabled = false
    var ipv6Subnet = ""
    var ipv6Gateway = ""
    var ipv6Range = ""

    func payload(name: String) throws -> [String: Any] {
        let subnet = subnet.trimmingCharacters(in: .whitespacesAndNewlines)
        let gateway = driver == .ipvlan && ipvlanMode != "l2" ? "" : gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = ipRange.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["Name": name, "Driver": driver.rawValue, "EnableIPv4": true]
        var configurations: [[String: String]] = []
        if driver == .bridge { body["Internal"] = internalOnly }
        if driver != .bridge {
            let parent = parent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard parent.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}$", options: .regularExpression) != nil, !subnet.isEmpty else {
                throw AppFailure(message: String(localized: "Für macvlan/ipvlan eine Linux-Schnittstelle und ein IPv4-Subnetz angeben."))
            }
            var options = ["parent": parent]
            if driver == .macvlan { options["macvlan_mode"] = "bridge" }
            else {
                guard ["l2", "l3", "l3s"].contains(ipvlanMode) else { throw AppFailure(message: String(localized: "Ungültiger IPvlan-Modus.")) }
                options["ipvlan_mode"] = ipvlanMode
            }
            body["Options"] = options
        }
        if subnet.isEmpty {
            guard gateway.isEmpty, range.isEmpty else { throw AppFailure(message: String(localized: "Für Gateway oder IP-Bereich zuerst ein Subnetz angeben.")) }
        } else {
            guard let network = IPv4Block(subnet), network.prefix <= 30 else {
                throw AppFailure(message: String(localized: "Subnetz als IPv4-Netzadresse mit Präfix 1–30 eingeben, zum Beispiel 192.168.111.0/24."))
            }
            var config = ["Subnet": subnet]
            if !gateway.isEmpty {
                guard let address = IPv4Block.address(gateway), address > network.first, address < network.last else {
                    throw AppFailure(message: String(localized: "Das Gateway muss eine Host-Adresse innerhalb des Subnetzes sein."))
                }
                config["Gateway"] = gateway
            }
            if !range.isEmpty {
                guard let pool = IPv4Block(range), pool.first >= network.first, pool.last <= network.last else {
                    throw AppFailure(message: String(localized: "Den IP-Bereich als ausgerichtetes CIDR-Netz innerhalb des Subnetzes eingeben; /32 erlaubt eine einzelne Adresse."))
                }
                config["IPRange"] = range
            }
            configurations.append(config)
        }
        body["EnableIPv6"] = ipv6Enabled
        if ipv6Enabled {
            let subnet = ipv6Subnet.trimmingCharacters(in: .whitespacesAndNewlines)
            let gateway = ipv6Gateway.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = ipv6Range.trimmingCharacters(in: .whitespacesAndNewlines)
            if subnet.isEmpty {
                guard driver == .bridge, gateway.isEmpty, range.isEmpty else { throw AppFailure(message: String(localized: "Für IPv6-Gateway oder IP-Bereich sowie Macvlan/IPvlan ein IPv6-Subnetz angeben.")) }
            } else {
                guard let block = IPv6Block(subnet) else { throw AppFailure(message: String(localized: "Ein ausgerichtetes IPv6-Subnetz als CIDR eingeben.")) }
                var entry = ["Subnet": subnet]
                if !gateway.isEmpty {
                    guard let address = IPv6Block.address(gateway), block.contains(address), address != block.first else { throw AppFailure(message: String(localized: "IPv6-Gateway muss innerhalb des Subnetzes liegen.")) }
                    entry["Gateway"] = gateway
                }
                if !range.isEmpty {
                    guard let pool = IPv6Block(range), block.contains(pool.first), block.contains(pool.last) else { throw AppFailure(message: String(localized: "IPv6-IP-Bereich muss innerhalb des Subnetzes liegen.")) }
                    entry["IPRange"] = range
                }
                configurations.append(entry)
            }
        }
        if !configurations.isEmpty { body["IPAM"] = ["Driver": "default", "Config": configurations] }
        return body
    }
}

private struct IPv4Block {
    let first: UInt32
    let last: UInt32
    let prefix: Int
    static func address(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), part.count == 1 || part.first != "0", let octet = UInt32(part), octet < 256 else { return nil }
            result = (result << 8) | octet
        }
        return result
    }
    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let address = Self.address(String(parts[0])), let prefix = Int(parts[1]), (1...32).contains(prefix) else { return nil }
        let mask = UInt32.max << (32 - prefix)
        guard address & mask == address else { return nil }
        self.first = address
        self.last = address | ~mask
        self.prefix = prefix
    }
}


private struct IPv6Block {
    let first: [UInt8]
    let last: [UInt8]
    static func address(_ text: String) -> [UInt8]? {
        var value = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &value) }) == 1 else { return nil }
        return withUnsafeBytes(of: &value) { Array($0) }
    }
    init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bytes = Self.address(String(parts[0])), let prefix = Int(parts[1]), (1...128).contains(prefix) else { return nil }
        let masks = (0..<16).map { index -> UInt8 in
            let bits = max(0, min(8, prefix - index * 8))
            return bits == 0 ? 0 : UInt8(truncatingIfNeeded: 255 << (8 - bits))
        }
        let first = zip(bytes, masks).map { $0 & $1 }
        guard first == bytes else { return nil }
        self.first = first
        self.last = zip(first, masks).map { $0 | ~$1 }
    }
    func contains(_ address: [UInt8]) -> Bool {
        !address.lexicographicallyPrecedes(first) && !last.lexicographicallyPrecedes(address)
    }
}

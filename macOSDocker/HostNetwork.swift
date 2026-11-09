import Foundation
import Darwin
import SystemConfiguration

enum HostNetwork {
    static func ipv4Address() -> String? {
        addresses(family: AF_INET).first
    }

    static func ipv6Addresses() -> [String] { addresses(family: AF_INET6) }

    private static func addresses(family: Int32) -> [String] {
        let key = family == AF_INET6 ? "State:/Network/Global/IPv6" : "State:/Network/Global/IPv4"
        let global = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any]
        let primary = global?["PrimaryInterface"] as? String
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(first) }
        var candidates: [(String, String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard let address = interface.ifa_addr, Int32(address.pointee.sa_family) == family,
                  interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bond") || (name == primary && name.hasPrefix("bridge")) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            if !ip.hasPrefix("169.254."), !ip.hasPrefix("127."), !ip.lowercased().hasPrefix("fe80:"), ip != "::1" { candidates.append((name, ip)) }
        }
        var result: [String] = []
        for candidate in candidates.sorted(by: { left, right in
            if (left.0 == primary) != (right.0 == primary) { return left.0 == primary }
            return (left.0, left.1) < (right.0, right.1)
        }) where !result.contains(candidate.1) { result.append(candidate.1) }
        return result
    }

}

enum PublishedPortAddress {
    static func forwardsIPv4Binding(_ binding: String, vmAddresses: [String]) -> Bool {
        !binding.contains(":") && (binding.isEmpty || binding == "0.0.0.0" || vmAddresses.contains(binding))
    }

    static func host(binding: String, type: String, port: Int, vmAddresses: [String], macAddress: String?, forwardedPorts: Set<UInt16>, nat: Bool, macIPv6Addresses: [String] = [], forwardedIPv6Ports: Set<UInt16> = []) -> String? {
        if binding.contains(":") {
            if nat, type == "tcp", let number = UInt16(exactly: port), forwardedIPv6Ports.contains(number), let address = macIPv6Addresses.first { return address }
            return binding == "::" ? vmAddresses.first(where: { $0.contains(":") }) : binding
        }
        let wildcard = binding.isEmpty || binding == "0.0.0.0"
        if nat, type == "tcp", let number = UInt16(exactly: port), number > 0,
           wildcard || vmAddresses.contains(binding), forwardedPorts.contains(number), let macAddress { return macAddress }
        return wildcard ? vmAddresses.first(where: { !$0.contains(":") }) : binding
    }

    static func hosts(binding: String, type: String, port: Int, vmAddresses: [String], macAddress: String?, forwardedPorts: Set<UInt16>, nat: Bool, macIPv6Addresses: [String] = [], forwardedIPv6Ports: Set<UInt16> = []) -> [String] {
        host(binding: binding, type: type, port: port, vmAddresses: vmAddresses, macAddress: macAddress, forwardedPorts: forwardedPorts, nat: nat, macIPv6Addresses: macIPv6Addresses, forwardedIPv6Ports: forwardedIPv6Ports).map { [$0] } ?? []
    }
}

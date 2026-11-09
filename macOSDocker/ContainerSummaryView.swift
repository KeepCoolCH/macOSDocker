import SwiftUI

struct ContainerSummaryView: View {
    @EnvironmentObject var runtime: RuntimeManager
    let data: Data?
    private var object: [String: Any] {
        guard let data else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    var body: some View {
        if data == nil {
            HStack { ProgressView().controlSize(.small); Text(String(localized: "Lädt …")) }
        } else {
            let root = object
            let config = root["Config"] as? [String: Any] ?? [:]
            let state = root["State"] as? [String: Any] ?? [:]
            let network = root["NetworkSettings"] as? [String: Any] ?? [:]
            let networks = network["Networks"] as? [String: [String: Any]] ?? [:]
            let ports = network["Ports"] as? [String: Any] ?? [:]
            let mounts = root["Mounts"] as? [[String: Any]] ?? []
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    card(String(localized: "Container")) {
                        Text((root["Name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))).font(.subheadline.bold())
                        Text(AppText.containerState(state["Status"] as? String ?? ""))
                        Text("ID: " + String((root["Id"] as? String ?? "").prefix(12)))
                        Text("Image: " + (config["Image"] as? String ?? "—"))
                    }
                    card(String(localized: "Veröffentlichte Ports")) {
                        let entries = portEntries(ports)
                        if entries.isEmpty { Text("—") }
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, value in Text(value) }
                    }
                    card(String(localized: "Netzwerke")) {
                        Text(String(localized: "VM-Anbindung: ") + (runtime.effectiveBridgeID.isEmpty ? "NAT" : "Bridge"))
                        if runtime.effectiveBridgeID.isEmpty {
                            Text(String(localized: "Mac-IPv4: ") + (runtime.macIPAddress ?? String(localized: "Nicht verfügbar")))
                        }
                        Text(String(localized: "VM-IP: ") + (runtime.vmIPAddresses.isEmpty ? String(localized: "Nicht verfügbar") : runtime.vmIPAddresses.joined(separator: ", ")))
                        if networks.isEmpty { Text("—") }
                        ForEach(networks.keys.sorted(), id: \.self) { name in
                            Text(networkDescription(name, settings: networks[name] ?? [:]))
                        }
                    }
                    card(String(localized: "Mounts")) {
                        if mounts.isEmpty { Text("—") }
                        ForEach(Array(mounts.sorted { ($0["Destination"] as? String ?? "") < ($1["Destination"] as? String ?? "") }.enumerated()), id: \.offset) { _, mount in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mount["Destination"] as? String ?? "—").bold()
                                Text(mount["Name"] as? String ?? mount["Source"] as? String ?? "—").foregroundStyle(.secondary)
                                Text((mount["Type"] as? String ?? "") + " · " + (mount["RW"] as? Bool == true ? "rw" : "ro")).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.textSelection(.enabled)
            }
        }
    }
    private func networkDescription(_ name: String, settings: [String: Any]) -> String {
        let networkID = settings["NetworkID"] as? String
        let driver = runtime.networks.first { $0.id == networkID || $0.Name == name }?.Driver ?? ""
        let addresses = [settings["IPAddress"] as? String, settings["GlobalIPv6Address"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if driver == "host" || name == "host" {
            return String(localized: "Docker-Netzwerk: ") + name + " · " + String(localized: "Verwendet die VM-IP")
        }
        let kind = ["macvlan", "ipvlan"].contains(driver) ? String(localized: "Direkte Container-IP") : String(localized: "Interne Container-IP")
        return String(localized: "Docker-Netzwerk: ") + name + (driver.isEmpty || driver == name ? "" : " (" + driver + ")") + " · " + kind + ": " + (addresses.isEmpty ? "—" : addresses)
    }
    private func portEntries(_ ports: [String: Any]) -> [String] {
        var result: [String] = []
        for port in ports.keys.sorted() {
            let bindings = ports[port] as? [[String: String]] ?? []
            for binding in bindings {
                let bound = binding["HostIp"] ?? ""
                let hostPort = binding["HostPort"] ?? ""
                let addresses = PublishedPortAddress.hosts(binding: bound, type: String(port.split(separator: "/").last ?? ""), port: Int(hostPort) ?? 0, vmAddresses: runtime.vmIPAddresses, macAddress: runtime.macIPAddress, forwardedPorts: runtime.forwardedTCPPorts, nat: runtime.effectiveBridgeID.isEmpty, macIPv6Addresses: runtime.macIPv6Addresses, forwardedIPv6Ports: runtime.forwardedIPv6TCPPorts)
                let local = bound == "::1" || bound.hasPrefix("127.")
                for address in addresses.isEmpty ? [String(localized: "Nicht verfügbar")] : addresses {
                    let host = address.contains(":") ? "[" + address + "]" : address
                    let entry = host + ":" + hostPort + " → " + port + (local ? " · " + String(localized: "Nur innerhalb der VM") : "")
                    if !result.contains(entry) { result.append(entry) }
                }
            }
        }
        return result
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content().font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

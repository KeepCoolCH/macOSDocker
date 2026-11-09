import SwiftUI

struct GuestSummaryView: View {
    let data: Data
    private var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    var body: some View {
        let root = object
        let interfaces = (root["addresses"] as? [[String: Any]] ?? []).sorted {
            let left = $0["ifname"] as? String ?? ""
            let right = $1["ifname"] as? String ?? ""
            return (left == "eth0" ? "" : left) < (right == "eth0" ? "" : right)
        }
        let shares = (root["shares"] as? [[String: Any]] ?? []).sorted {
            ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "")
        }
        VStack(alignment: .leading, spacing: 8) {
            card(String(localized: "Gaststatus")) {
                LabeledContent(String(localized: "Gastdienst")) {
                    Text(root["ready"] as? Bool == true ? String(localized: "Bereit") : String(localized: "Nicht bereit"))
                }
                LabeledContent(String(localized: "Docker-Socket")) {
                    Text(root["dockerSocket"] as? Bool == true ? String(localized: "Vorhanden") : String(localized: "Nicht vorhanden"))
                }
            }
            ForEach(Array(interfaces.enumerated()), id: \.offset) { _, interface in
                card(interface["ifname"] as? String ?? "—") {
                    let flags = interface["flags"] as? [String] ?? []
                    Text(flags.contains("UP") ? String(localized: "Schnittstelle aktiviert") : String(localized: "Schnittstelle deaktiviert"))
                    let addresses = (interface["addr_info"] as? [[String: Any]] ?? []).filter { ["inet", "inet6"].contains($0["family"] as? String ?? "") }
                    if addresses.isEmpty { Text(String(localized: "Keine IP-Adresse zugewiesen")) }
                    ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                        let ip = address["local"] as? String ?? "—"
                        let prefix = (address["prefixlen"] as? Int).map { "/" + String($0) } ?? ""
                        Text((address["family"] as? String == "inet6" ? "IPv6: " : "IPv4: ") + ip + prefix)
                    }
                    if let mac = interface["address"] as? String {
                        Text("MAC: " + mac).foregroundStyle(.secondary)
                    }
                    if let mtu = interface["mtu"] as? Int {
                        Text("MTU: " + String(mtu)).foregroundStyle(.secondary)
                    }
                }
            }
            card(String(localized: "Mac-Freigaben")) {
                if shares.isEmpty { Text(String(localized: "Keine Freigaben gemountet")) }
                ForEach(Array(shares.enumerated()), id: \.offset) { _, share in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(share["path"] as? String ?? "—")
                        Text(share["readonly"] as? Bool == true ? String(localized: "Schreibgeschützt") : String(localized: "Lesen und Schreiben"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }.textSelection(.enabled)
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content().font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

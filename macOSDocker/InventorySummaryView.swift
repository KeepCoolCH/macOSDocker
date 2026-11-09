import SwiftUI

struct InventorySummary {
    let section: String
    let data: Data
    var users: Data? = nil
}

struct InventorySummaryView: View {
    let summary: InventorySummary
    private var root: [String: Any] {
        (try? JSONSerialization.jsonObject(with: summary.data)) as? [String: Any] ?? [:]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if summary.section == "Images" {
                card(String(localized: "Image")) {
                    let tags = root["RepoTags"] as? [String] ?? []
                    Text(tags.isEmpty ? "—" : tags.sorted().joined(separator: "\n")).bold()
                    row("ID", value: root["Id"] as? String)
                    row(String(localized: "Grösse"), value: (root["Size"] as? NSNumber).map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .file) })
                    row(String(localized: "Plattform"), value: [root["Os"], root["Architecture"], root["Variant"]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: "/"))
                    row(String(localized: "Erstellt"), value: root["Created"] as? String)
                }
                card(String(localized: "Startkonfiguration")) {
                    let config = root["Config"] as? [String: Any] ?? [:]
                    row("Entrypoint", value: (config["Entrypoint"] as? [String])?.joined(separator: " "))
                    row("Cmd", value: (config["Cmd"] as? [String])?.joined(separator: " "))
                    row(String(localized: "Arbeitsverzeichnis"), value: config["WorkingDir"] as? String)
                    row(String(localized: "Benutzer"), value: config["User"] as? String)
                }
            } else if summary.section == "Volumes" {
                card(String(localized: "Volume")) {
                    Text(root["Name"] as? String ?? "—").bold()
                    row(String(localized: "Treiber"), value: root["Driver"] as? String)
                    row("Scope", value: root["Scope"] as? String)
                    row("IPv4", value: root["EnableIPv4"] as? Bool == false ? String(localized: "Nein") : String(localized: "Ja"))
                    row(String(localized: "Pfad in der VM"), value: root["Mountpoint"] as? String)
                    row(String(localized: "Erstellt"), value: root["CreatedAt"] as? String)
                }
                card(String(localized: "Verwendende Container")) {
                    let users = summary.users.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? []
                    let lines = users.map { item in
                        let name = (item["Names"] as? [String])?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? String((item["Id"] as? String ?? "").prefix(12))
                        return name + " · " + AppText.containerState(item["State"] as? String ?? "")
                    }.sorted()
                    linesView(lines)
                }
            } else if summary.section == "Netzwerke" {
                card(String(localized: "Netzwerk")) {
                    row("IPv6", value: root["EnableIPv6"] as? Bool == true ? String(localized: "Ja") : String(localized: "Nein"))
                    Text(root["Name"] as? String ?? "—").bold()
                    row("ID", value: String((root["Id"] as? String ?? "").prefix(12)))
                    row(String(localized: "Treiber"), value: root["Driver"] as? String)
                    row("Scope", value: root["Scope"] as? String)
                    row(String(localized: "Internes Netzwerk"), value: root["Internal"] as? Bool == true ? String(localized: "Ja") : String(localized: "Nein"))
                }
                card(String(localized: "Subnetze")) {
                    let ipam = root["IPAM"] as? [String: Any] ?? [:]
                    let configs = ipam["Config"] as? [[String: Any]] ?? []
                    let lines = configs.map { config in
                        (config["Subnet"] as? String ?? "—") + " · Gateway: " + (config["Gateway"] as? String ?? "—")
                    }.sorted()
                    linesView(lines)
                }
                card(String(localized: "Container")) {
                    let containers = root["Containers"] as? [String: [String: Any]] ?? [:]
                    let lines = containers.map { id, item in
                        let addresses = [item["IPv4Address"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
                        return (item["Name"] as? String ?? String(id.prefix(12))) + (addresses.isEmpty ? "" : " · " + addresses.joined(separator: ", "))
                    }.sorted()
                    linesView(lines)
                }
            }
        }.textSelection(.enabled)
    }
    private func row(_ title: String, value: String?) -> some View {
        Text(title + ": " + ((value?.isEmpty == false) ? value! : "—"))
    }
    private func linesView(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if lines.isEmpty { Text("—") }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line) }
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content().font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

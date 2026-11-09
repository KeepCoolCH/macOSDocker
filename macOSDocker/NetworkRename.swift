import Foundation

enum NetworkRename {
    static func payload(_ source: [String: Any], name: String) throws -> [String: Any] {
        guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,254}$", options: .regularExpression) != nil,
              !["bridge", "host", "none"].contains(name) else {
            throw AppFailure(message: String(localized: "Ungültiger Netzwerkname. Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich verwenden; Systemnamen sind reserviert."))
        }
        guard let oldName = source["Name"] as? String, !["bridge", "host", "none"].contains(oldName),
              let driver = source["Driver"] as? String, ["bridge", "macvlan", "ipvlan"].contains(driver),
              source["Scope"] as? String == "local",
              source["Ingress"] as? Bool != true, source["ConfigOnly"] as? Bool != true,
              ((source["ConfigFrom"] as? [String: Any])?["Network"] as? String ?? "").isEmpty else {
            throw AppFailure(message: String(localized: "Nur eigene lokale Bridge-, macvlan- und ipvlan-Netzwerke können umbenannt werden."))
        }
        guard (source["Containers"] as? [String: Any] ?? [:]).isEmpty else {
            throw AppFailure(message: String(localized: "Das Netzwerk wird von Containern verwendet. Diese zuerst vom Netzwerk trennen; Stoppen allein genügt nicht."))
        }
        var result: [String: Any] = ["Name": name]
        for key in ["Driver", "Scope", "Internal", "Attachable", "EnableIPv4", "EnableIPv6", "IPAM", "Options", "Labels"] {
            if let value = source[key] { result[key] = value }
        }
        return result
    }

    static func migrate(id: String, name: String, backupDirectory: URL,
                        request: (String, String, Data?) async throws -> Data) async throws {
        let original = try await request("GET", "/networks/" + id, nil)
        guard let source = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              let oldName = source["Name"] as? String else { throw AppFailure(message: String(localized: "Ungültige Netzwerkantwort.")) }
        if oldName == name { return }
        let newPayload = try payload(source, name: name)
        let oldPayload = try payload(source, name: oldName)
        let networksData = try await request("GET", "/networks", nil)
        guard let networks = try JSONSerialization.jsonObject(with: networksData) as? [[String: Any]] else {
            throw AppFailure(message: String(localized: "Ungültige Netzwerkantwort."))
        }
        guard !networks.contains(where: { $0["Name"] as? String == name }) else {
            throw AppFailure(message: String(localized: "Ein Netzwerk mit diesem Namen existiert bereits."))
        }
        let containersData = try await request("GET", "/containers/json?all=1", nil)
        guard let containers = try JSONSerialization.jsonObject(with: containersData) as? [[String: Any]] else {
            throw AppFailure(message: String(localized: "Ungültige Netzwerkantwort."))
        }
        for container in containers {
            let endpoints = (container["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: [String: Any]] ?? [:]
            let mode = (container["HostConfig"] as? [String: Any])?["NetworkMode"] as? String
            if endpoints[oldName] != nil || endpoints.values.contains(where: { $0["NetworkID"] as? String == id }) || mode == oldName || mode == id {
                throw AppFailure(message: String(localized: "Das Netzwerk wird von Containern verwendet. Diese zuerst vom Netzwerk trennen; Stoppen allein genügt nicht."))
            }
        }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = backupDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let oldBody = try JSONSerialization.data(withJSONObject: oldPayload, options: [.prettyPrinted, .sortedKeys])
        try oldBody.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        _ = try await request("DELETE", "/networks/" + id, nil)
        do {
            _ = try await request("POST", "/networks/create", JSONSerialization.data(withJSONObject: newPayload))
        } catch {
            let creationError = error.localizedDescription
            let currentData = try? await request("GET", "/networks", nil)
            let current = currentData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
            guard let current, !current.contains(where: { $0["Name"] as? String == name || $0["Name"] as? String == oldName }) else {
                throw AppFailure(message: String(localized: "Netzwerkzustand nach Fehler unklar. Bitte Netzwerke prüfen. Wiederherstellungskonfiguration: ") + backup.path + "\n" + creationError)
            }
            do { _ = try await request("POST", "/networks/create", oldBody) }
            catch {
                throw AppFailure(message: String(localized: "Umbenennen und Wiederherstellen fehlgeschlagen. Wiederherstellungskonfiguration: ") + backup.path + "\n" + creationError + "\n" + error.localizedDescription)
            }
            throw AppFailure(message: String(localized: "Umbenennen fehlgeschlagen. Das Netzwerk wurde unter dem bisherigen Namen wiederhergestellt.") + "\n" + creationError)
        }
        try? FileManager.default.removeItem(at: backup)
    }
}


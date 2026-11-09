import Foundation

struct AppUpdate: Decodable, Equatable, Sendable {
    let version: String
    let build: Int
    let downloadURL: URL

    static func decode(_ data: Data) throws -> Self {
        let update = try JSONDecoder().decode(Self.self, from: data)
        guard update.build > 0, !update.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              update.version.count <= 128, update.downloadURL.scheme?.lowercased() == "https",
              let host = update.downloadURL.host, !host.isEmpty,
              update.downloadURL.user == nil, update.downloadURL.password == nil else {
            throw AppFailure(message: String(localized: "Die Updateinformationen sind ungültig."))
        }
        let downloadHost = host.lowercased()
        guard downloadHost == "kevintobler.ch" || downloadHost.hasSuffix(".kevintobler.ch"),
              update.downloadURL.port == nil || update.downloadURL.port == 443 else {
            throw AppFailure(message: String(localized: "Downloadadressen sind nur auf kevintobler.ch und dessen Subdomains über HTTPS erlaubt."))
        }
        return update
    }

    static func fetch(from url: URL, session: URLSession) async throws -> Self {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme?.lowercased() == "https" else {
            throw AppFailure(message: String(localized: "Der Updateserver hat keine gültige Antwort geliefert."))
        }
        let limit = 1024 * 1024
        guard response.expectedContentLength <= limit else { throw AppFailure(message: String(localized: "Die Updateinformationen sind zu gross.")) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw AppFailure(message: String(localized: "Die Updateinformationen sind zu gross.")) }
            data.append(byte)
        }
        return try decode(data)
    }
}

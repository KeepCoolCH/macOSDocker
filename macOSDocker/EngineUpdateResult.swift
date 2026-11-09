import Foundation

struct EngineUpdateResult {
    let updates: [String]
    let availableVersion: String
    var available: Bool { !updates.isEmpty }
    init(output: String, installedVersion: String) {
        updates = output.split(whereSeparator: \.isNewline).map(String.init).filter {
            let columns = $0.split(whereSeparator: \.isWhitespace)
            return columns.count == 3 && columns[1] == "<"
        }
        availableVersion = updates.first(where: { $0.hasPrefix("docker-engine-") })?
            .split(whereSeparator: \.isWhitespace).last.map(String.init) ?? installedVersion
    }
}

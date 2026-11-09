import Foundation

struct BuildRecord: Decodable, Identifiable {
    let ref: String
    let name: String
    let status: String
    let created_at: String?
    let completed_at: String?
    let total_steps: Int?
    let completed_steps: Int?
    let cached_steps: Int?
    var id: String { ref }
    var recordID: String { String(ref.split(separator: "/").last ?? Substring(ref)) }

    static func decode(_ data: Data) throws -> [Self] {
        if data.allSatisfy({ [9, 10, 13, 32].contains($0) }) { return [] }
        let decoder = JSONDecoder()
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
            return try decoder.decode([Self].self, from: data)
        }
        return try data.split(separator: 10).filter { !$0.allSatisfy({ [9, 13, 32].contains($0) }) }
            .map { try decoder.decode(Self.self, from: Data($0)) }
    }

    var createdDate: Date? { Self.date(created_at) }
    var duration: String? {
        guard let start = createdDate, let end = Self.date(completed_at) else { return nil }
        return String(format: "%.1f s", max(0, end.timeIntervalSince(start)))
    }
    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}


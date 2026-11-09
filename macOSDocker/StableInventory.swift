import Foundation

enum StableInventory {
    static func merge<Item: Identifiable>(previous: [Item], incoming: [Item], name: (Item) -> String) -> [Item] where Item.ID == String {
        var latest: [String: Item] = [:]
        for item in incoming { latest[item.id] = item }
        var result: [Item] = []
        for item in previous {
            if let updated = latest.removeValue(forKey: item.id) { result.append(updated) }
        }
        result.append(contentsOf: latest.values.sorted { left, right in
            let order = name(left).localizedStandardCompare(name(right))
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        })
        return result
    }
}

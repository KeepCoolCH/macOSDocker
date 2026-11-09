import Foundation

@MainActor
enum InventoryPoller {
    static func run(interval: Duration = .seconds(3),
                    update: @escaping @MainActor () async throws -> Void,
                    onFailure: @escaping @MainActor (Error) -> Void) async {
        while !Task.isCancelled {
            do {
                try await update()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                onFailure(error)
            }
            do { try await Task.sleep(for: interval) }
            catch { return }
        }
    }
}

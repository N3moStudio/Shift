import Combine
import Foundation

@MainActor
final class RecentlyDeletedStore: ObservableObject {
    static let shared = RecentlyDeletedStore()
    @Published private(set) var items: [DeletedLibraryItem] = []
    @Published var error: String?
    private var loadFailed = false
    private let file: URL
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Locus/RecentlyDeleted.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= LibraryBackup.maximumBytes else { throw BackupError.tooLarge }
            let loaded = try JSONDecoder().decode([DeletedLibraryItem].self, from: data)
            guard loaded.count <= 2000, loaded.allSatisfy({ $0.payload.isValid }),
                  Set(loaded.map(\.id)).count == loaded.count else { throw BackupError.invalid }
            items = loaded
            prune()
        } catch {
            loadFailed = true
            self.error = "Recently Deleted could not be read. Its file was kept. Nothing else will be deleted."
        }
    }
    func prune(now: Date = Date()) {
        let kept = items.filter { $0.isRetained(at: now) }
        if kept != items { _ = write(kept) }
    }
    func keep(_ payload: DeletedPayload) -> UUID? {
        guard payload.isValid else { error = "This item could not be moved to Recently Deleted."; return nil }
        let entry = DeletedLibraryItem(payload: payload)
        let updated = [entry] + items.filter { $0.isRetained(at: Date()) }
        guard updated.count <= 2000 else { error = "Recently Deleted is full. Permanently delete an item there first."; return nil }
        return write(updated) ? entry.id : nil
    }
    @discardableResult func remove(_ id: UUID) -> Bool { write(items.filter { $0.id != id }) }
    @discardableResult func clear(kind: String) -> Bool { write(items.filter { $0.payload.kind != kind }) }
    private func write(_ updated: [DeletedLibraryItem]) -> Bool {
        guard !loadFailed else { return false }
        do {
            let data = try JSONEncoder().encode(updated)
            guard data.count <= LibraryBackup.maximumBytes else { throw BackupError.tooLarge }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            items = updated
            error = nil
            return true
        } catch { self.error = "Couldn't save Recently Deleted. Your original items were kept. Free some storage and try again."; return false }
    }
}

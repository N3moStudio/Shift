import Combine
import Foundation

@MainActor
final class TripRecoveryStore: ObservableObject {
    @Published private(set) var checkpoint: TripCheckpoint?
    @Published private(set) var error: String?
    @Published var enabled = UserDefaults.standard.object(forKey: "locus.tripRecovery") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "locus.tripRecovery")
            if !enabled { discard() }
        }
    }
    private let queue = DispatchQueue(label: "locus.trip-checkpoint", qos: .utility)
    private var revision = UUID()
    private var lastWrite = Date.distantPast
    private let file: URL

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Locus/TripCheckpoint.json")
        guard enabled, UserDefaults.standard.bool(forKey: "locus.checkpointAvailable"), FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= LibraryBackup.maximumBytes else { throw BackupError.tooLarge }
            let value = try JSONDecoder().decode(TripCheckpoint.self, from: Data(contentsOf: file))
            guard value.isValid else { throw BackupError.invalid }
            checkpoint = value
        } catch { self.error = "The saved trip checkpoint couldn't be read. Your saved library is unaffected." }
    }

    func shouldSave(force: Bool, now: Date = Date()) -> Bool {
        enabled && (force || now.timeIntervalSince(lastWrite) >= 10)
    }
    func save(_ value: TripCheckpoint) {
        guard enabled, value.isValid else { return }
        let token = UUID()
        revision = token
        lastWrite = Date()
        let file = file
        queue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var protected = file
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try protected.setResourceValues(values)
                Task { @MainActor [weak self] in
                    guard let self, self.revision == token else { return }
                    UserDefaults.standard.set(true, forKey: "locus.checkpointAvailable")
                    self.checkpoint = value
                    self.error = nil
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.revision == token else { return }
                    self.error = "Couldn't save the latest recovery point. Movement can continue, but recovery may use an older point."
                }
            }
        }
    }
    func discard() {
        UserDefaults.standard.set(false, forKey: "locus.checkpointAvailable")
        revision = UUID()
        checkpoint = nil
        let file = file
        let token = revision
        queue.async { [weak self] in
            do {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                Task { @MainActor [weak self] in
                    guard self?.revision == token else { return }; self?.error = nil
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard self?.revision == token else { return }
                    self?.error = "Couldn't remove the saved recovery point. Try again in Trip recovery."
                }
            }
        }
    }
}

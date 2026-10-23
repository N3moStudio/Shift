import Foundation

enum PairingFileImport {
    static let maximumBytes = 1024 * 1024

    enum Failure: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: return "This isn't a valid RPPairing file. Your existing pairing has not changed."
            case .tooLarge: return "Pairing files must be smaller than 1 MB. Your existing pairing has not changed."
            }
        }
    }

    /// A vendor decoder must accept the staged file before the live file changes.
    static func install(_ data: Data, at destination: URL, validate: (URL) throws -> Void) throws {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard !data.isEmpty,
              let contents = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              contents is [String: Any] else {
            throw Failure.invalid
        }
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".pairing-\(UUID().uuidString).plist")
        defer { try? manager.removeItem(at: staged) }
        #if os(iOS)
        try data.write(to: staged, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: staged, options: .atomic)
        #endif
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        try validate(staged)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }
}

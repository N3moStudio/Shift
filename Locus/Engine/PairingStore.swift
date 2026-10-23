import Foundation
import UniformTypeIdentifiers
import UIKit
import idevice

@MainActor
final class PairingStore: ObservableObject {
    @Published private(set) var hasPairingFile = false
    @Published private(set) var revision = UUID()
    @Published var lastError: String?

    static let fileName = "rp_pairing_file.plist"
    static let supportedTypes: [UTType] = {
        var types: [UTType] = [
            .item,          // anything — sideloaded plists often lack a proper UTI
            .data,
            .propertyList,
            .xml,
        ]
        for ext in ["plist", "mobiledevicepairing", "mobiledevicepair"] {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        if let custom = UTType("com.n3mostudio.shift.rppairing") {
            types.append(custom)
        }
        return types
    }()

    private var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    var pairingURL: URL {
        directoryURL.appendingPathComponent(Self.fileName)
    }

    var pairingPath: String { pairingURL.path }

    init() {
        refresh()
    }

    func refresh() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        hasPairingFile = FileManager.default.fileExists(atPath: pairingURL.path)
        // On-device pairing writes outside this store, then calls refresh.
        // Conservatively invalidate any proof made before that refresh.
        revision = UUID()
    }

    func importPairing(from sourceURL: URL) throws {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let file = try FileHandle(forReadingFrom: sourceURL)
        defer { try? file.close() }
        let data = try file.read(upToCount: PairingFileImport.maximumBytes + 1) ?? Data()
        try installPairingData(data)
    }

    /// LiveContainer / broken pickers: copy the plist text (or file) then paste here.
    func importPairingFromClipboard() throws {
        let board = UIPasteboard.general

        if let url = board.url ?? board.urls?.first {
            if url.isFileURL {
                try importPairing(from: url)
                return
            }
        }

        let candidates: [Data?] = [
            board.data(forPasteboardType: "com.apple.property-list"),
            board.data(forPasteboardType: UTType.propertyList.identifier),
            board.data(forPasteboardType: UTType.xml.identifier),
            board.data(forPasteboardType: UTType.data.identifier),
            board.string?.data(using: .utf8),
        ]

        guard let data = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw PairingImportError.emptyClipboard
        }
        try installPairingData(data)
    }

    func removePairing() throws {
        if FileManager.default.fileExists(atPath: pairingURL.path) {
            try FileManager.default.removeItem(at: pairingURL)
        }
        hasPairingFile = false
        revision = UUID()
    }

    private func installPairingData(_ data: Data) throws {
        try PairingFileImport.install(data, at: pairingURL) { staged in
            var handle: OpaquePointer?
            let error = staged.path.withCString { rp_pairing_file_read($0, &handle) }
            defer { if let handle { rp_pairing_file_free(handle) } }
            if let error {
                idevice_error_free(error)
                throw PairingImportError.invalidContents
            }
            guard handle != nil else { throw PairingImportError.invalidContents }
        }
        hasPairingFile = true
        revision = UUID()
        lastError = nil
    }
}

enum PairingImportError: LocalizedError {
    case emptyClipboard
    case invalidContents

    var errorDescription: String? {
        switch self {
        case .emptyClipboard:
            return "Clipboard is empty. Copy your RPPairing plist text (or the file), then try Paste again."
        case .invalidContents:
            return "That pairing file could not be read. Your existing pairing has not changed. Import the full RPPairing file and try again."
        }
    }
}

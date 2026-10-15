import Foundation

enum DeletedPayload: Codable, Equatable {
    case place(BackupPlace), trip(SavedTrip), area(NamedArea)
    var name: String {
        switch self { case .place(let v): return v.name; case .trip(let v): return v.name; case .area(let v): return v.name }
    }
    var kind: String {
        switch self { case .place: return "Saved place"; case .trip: return "Saved trip"; case .area: return "Named area" }
    }
    var isValid: Bool {
        switch self { case .place(let v): return v.isValid; case .trip(let v): return v.isValid; case .area(let v): return v.isValid }
    }
}

struct DeletedLibraryItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var deletedAt = Date()
    var payload: DeletedPayload
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    var expiresAt: Date { deletedAt.addingTimeInterval(Self.lifetime) }
    func isRetained(at now: Date) -> Bool {
        payload.isValid && deletedAt.timeIntervalSince1970.isFinite && expiresAt > now
    }
}

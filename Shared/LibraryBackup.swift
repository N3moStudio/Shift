import Foundation

struct BackupPlace: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    var folder: String?
    var icon: String? = nil
    var color: String? = nil
    var id: String { "\(latitude),\(longitude)" }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120 &&
        RoutePoint(latitude: latitude, longitude: longitude).isValid &&
        (folder.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 60 } ?? true) &&
        (icon.map { $0.count <= 64 } ?? true) && (color.map { $0.count <= 32 } ?? true)
    }
}

/// Deliberate allowlist: no pairing, tunnel address, lock state, recents or diagnostics.
struct BackupPreferences: Codable, Equatable {
    var usualSpeeds: [String: Double]
    var glassPanel: Bool
    var appearance: String
    var smoothMovement: Bool
    var preferWalkingPaths: Bool
    var shortcuts: [PanelShortcut]
    var display: BackupDisplayPreferences? = nil
    var isValid: Bool {
        (display?.isValid ?? true) && ["system", "light", "dark"].contains(appearance) &&
        (shortcuts == PanelShortcut.normalized(shortcuts) ||
            (shortcuts.contains(.batterySaver) && shortcuts.count <= 3 && Set(shortcuts).count == shortcuts.count)) &&
        usualSpeeds.count <= TravelMode.allCases.count && usualSpeeds.allSatisfy { key, value in
            guard let mode = TravelMode(rawValue: key) else { return false }
            return value.isFinite && mode.speedRangeMPH.contains(value)
        }
    }
}

enum BackupCategory: String, Codable, CaseIterable, Identifiable {
    case places, trips, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .places: return "Saved places & named areas"; case .trips: return "Saved trips & routines"; case .settings: return "Settings" }
    }
}

struct BackupDisplayPreferences: Codable, Equatable {
    var liveActivities: Bool
    var hideLocation: Bool
    var hideIslandLocation: Bool
    var lockScreenProgress: Bool
    var islandProgress: Bool
    var islandTimer: Bool
    var connectionAlerts: Bool
    var reminderMinutes: Int
    var saveRecentLocations: Bool
    var recentHistoryRetention: RecentHistoryRetention
    var mapStyle: Int
    var connectionCheckSeconds: Int? = nil
    var isValid: Bool {
        [0, 15, 30, 60, 120].contains(reminderMinutes) && (0...2).contains(mapStyle) &&
            (connectionCheckSeconds.map { (3...15).contains($0) } ?? true)
    }
}

struct LibraryBackup: Codable {
    var format = "Shift library"
    var version = 2
    var createdAt = Date()
    var places: [BackupPlace]
    var trips: [SavedTrip]
    var preferences: BackupPreferences?
    var areas: [NamedArea]? = nil
    var categories: [BackupCategory]? = nil
    var included: Set<BackupCategory> { Set(categories ?? BackupCategory.allCases) }

    func selecting(_ selection: Set<BackupCategory>) -> Self {
        var copy = self
        copy.version = 2
        copy.categories = BackupCategory.allCases.filter { selection.contains($0) }
        if !selection.contains(.places) { copy.places = []; copy.areas = nil }
        if !selection.contains(.trips) { copy.trips = [] }
        if !selection.contains(.settings) { copy.preferences = nil }
        return copy
    }
    static let maximumBytes = 32 * 1024 * 1024
    var isValid: Bool {
        ["Shift library", "Locus library"].contains(format) && [1, 2].contains(version) && !included.isEmpty &&
        (categories.map { Set($0).count == $0.count } ?? true) &&
        (included.contains(.settings) ? preferences?.isValid == true : preferences == nil) &&
        (included.contains(.places) || (places.isEmpty && (areas ?? []).isEmpty)) &&
        (included.contains(.trips) || trips.isEmpty) &&
        (areas ?? []).count <= 100 && (areas ?? []).allSatisfy(\.isValid) &&
        Set((areas ?? []).map(\.id)).count == (areas ?? []).count && createdAt.timeIntervalSince1970.isFinite && places.count <= 1000 && trips.count <= 50 &&
        places.allSatisfy(\.isValid) && trips.allSatisfy {
            $0.isValid && $0.originName.count <= 240 && $0.destinationName.count <= 240 &&
            $0.instructions.count <= 10_000 && $0.instructions.allSatisfy { $0.text.count <= 2000 }
        } &&
        Set(places.map(\.id)).count == places.count && Set(trips.map(\.id)).count == trips.count &&
        trips.reduce(0, { $0 + $1.points.count }) <= 500_000
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        var value = try JSONDecoder().decode(Self.self, from: data)
        guard value.isValid else { throw BackupError.invalid }
        if let shortcuts = value.preferences?.shortcuts {
            value.preferences?.shortcuts = PanelShortcut.normalized(shortcuts)
        }
        return value
    }
    func encoded() throws -> Data {
        guard isValid else { throw BackupError.invalid }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw BackupError.tooLarge }
        return data
    }
}

enum BackupError: LocalizedError {
    case invalid, tooLarge, capacity
    var errorDescription: String? {
        switch self {
        case .invalid: return "This backup is damaged or uses a version Shift cannot read. Nothing was imported."
        case .tooLarge: return "This backup is too large. The limit is 32 MB."
        case .capacity: return "There isn't room for this backup. Shift supports 50 trips, 1,000 saved places, and 100 named areas. Nothing was imported."
        }
    }
}

enum LibraryMerge {
    static func areas(local: [NamedArea], incoming: [NamedArea]) throws -> [NamedArea] {
        var ids = Set(local.map(\.id))
        let result = local + incoming.filter { ids.insert($0.id).inserted }
        guard result.count <= 100, result.allSatisfy(\.isValid) else { throw BackupError.capacity }
        return result
    }

    /// Keep local versions of matching entries. Reimporting never duplicates them.
    static func trips(local: [SavedTrip], incoming: [SavedTrip]) throws -> [SavedTrip] {
        var ids = Set(local.map(\.id))
        let result = local + incoming.filter { ids.insert($0.id).inserted }
        guard result.count <= 50, result.reduce(0, { $0 + $1.points.count }) <= 500_000 else { throw BackupError.capacity }
        return result
    }
    static func places(local: [BackupPlace], incoming: [BackupPlace]) throws -> [BackupPlace] {
        var ids = Set(local.map(\.id))
        let result = local + incoming.filter { ids.insert($0.id).inserted }
        guard result.count <= 1000 else { throw BackupError.capacity }
        return result
    }
}

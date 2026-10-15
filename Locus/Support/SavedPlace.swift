import CoreLocation
import Foundation

struct SavedPlace: Identifiable, Codable, Equatable {
    var id: String { "\(latitude),\(longitude)" }
    var name: String
    var displayName: String { PlaceLabel.readable(name) }
    var latitude: Double
    var longitude: Double
    var visitedAt: Date? = nil
    var folder: String? = nil
    var icon: String? = nil
    var color: String? = nil
    var symbol: SavedPlaceSymbol { icon.flatMap(SavedPlaceSymbol.init(rawValue:)) ?? .pin }
    var tint: SavedPlaceTint { color.flatMap(SavedPlaceTint.init(rawValue:)) ?? .mint }
    var backupPlace: BackupPlace { BackupPlace(name: name, latitude: latitude, longitude: longitude, folder: folder, icon: icon, color: color) }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func load(key: String) -> [SavedPlace] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedPlace].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ places: [SavedPlace], key: String) {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func loadRecents(retention: RecentHistoryRetention, saveEnabled: Bool, now: Date = Date()) -> [SavedPlace] {
        saveRecents(load(key: "locus.recents"), retention: retention, saveEnabled: saveEnabled, now: now)
    }

    @discardableResult
    static func saveRecents(_ places: [SavedPlace], retention: RecentHistoryRetention, saveEnabled: Bool, now: Date = Date()) -> [SavedPlace] {
        guard saveEnabled else {
            UserDefaults.standard.removeObject(forKey: "locus.recents")
            return []
        }
        let kept = Array(places.filter {
            $0.latitude.isFinite && $0.longitude.isFinite && (-90...90).contains($0.latitude)
                && (-180...180).contains($0.longitude) && retention.keeps(visitedAt: $0.visitedAt, now: now)
        }.prefix(20))
        if kept.isEmpty { UserDefaults.standard.removeObject(forKey: "locus.recents") }
        else if kept != load(key: "locus.recents") { save(kept, key: "locus.recents") }
        return kept
    }
}

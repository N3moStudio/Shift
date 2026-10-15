import Foundation

enum TripEditReason: String, Codable {
    case route, path, name, labels, folder, restore
    var title: String {
        switch self {
        case .route: return "Before saving route changes"
        case .path: return "Before editing the drawn path"
        case .name: return "Before renaming"
        case .labels: return "Before changing place names"
        case .folder: return "Before moving folders"
        case .restore: return "Before restoring an earlier version"
        }
    }
}

struct TripRevision: Identifiable, Codable, Equatable {
    var id = UUID()
    let replacedAt: Date
    let reason: TripEditReason
    let trip: SavedTrip
    var isValid: Bool { replacedAt.timeIntervalSince1970.isFinite && trip.isValid }
}

/// Current trips and previous versions are committed in ONE atomic file, so a
/// failed save cannot leave the new path without its corresponding old version.
struct TripLibraryDocument: Codable, Equatable {
    static let historyLimit = 3
    static let maximumBytes = 128 * 1024 * 1024
    var format = 1
    var trips: [SavedTrip] = []
    var revisions: [TripRevision] = []

    var isValid: Bool {
        guard format == 1, trips.count <= 50, trips.allSatisfy(\.isValid),
              Set(trips.map(\.id)).count == trips.count,
              revisions.count <= 50 * Self.historyLimit,
              Set(revisions.map(\.id)).count == revisions.count,
              revisions.allSatisfy(\.isValid) else { return false }
        let ids = Set(trips.map(\.id))
        let grouped = Dictionary(grouping: revisions, by: { $0.trip.id })
        return grouped.allSatisfy { ids.contains($0.key) && $0.value.count <= Self.historyLimit }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder()
        let value: Self
        if let legacy = try? decoder.decode([SavedTrip].self, from: data) {
            value = Self(trips: legacy)
        } else { value = try decoder.decode(Self.self, from: data) }
        guard value.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    func updating(to updated: [SavedTrip], reason: TripEditReason, now: Date = Date()) throws -> Self {
        guard isValid, now.timeIntervalSince1970.isFinite,
              updated.count <= 50, updated.allSatisfy(\.isValid), Set(updated.map(\.id)).count == updated.count else {
            throw CocoaError(.fileWriteUnknown)
        }
        let previous = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
        var kept: [TripRevision] = []
        for trip in updated {
            var history = revisions.filter { $0.trip.id == trip.id && !$0.trip.hasSameSavedContent(as: trip) }
            if let old = previous[trip.id], !old.hasSameSavedContent(as: trip) {
                history.insert(TripRevision(replacedAt: now, reason: reason, trip: old), at: 0)
            }
            kept.append(contentsOf: history.prefix(Self.historyLimit))
        }
        return Self(trips: updated, revisions: kept)
    }

    func restoring(_ revisionID: UUID, tripID: UUID, expected: SavedTrip, now: Date = Date()) throws -> Self {
        guard let index = trips.firstIndex(where: { $0.id == tripID }), trips[index] == expected,
              let revision = revisions.first(where: { $0.id == revisionID && $0.trip.id == tripID }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var changed = trips
        changed[index] = revision.trip
        changed[index].savedAt = now
        return try updating(to: changed, reason: .restore, now: now)
    }

    func encoded() throws -> Data {
        guard isValid else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return data
    }
}

extension SavedTrip {
    func hasSameSavedContent(as other: SavedTrip) -> Bool {
        var value = self
        value.savedAt = other.savedAt
        return value == other
    }
}

enum SavedNameSearch {
    static func matches(_ query: String, fields: [String]) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            fields.contains { $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil }
        }
    }

    static func matches(_ query: String, trip: SavedTrip) -> Bool {
        matches(query, fields: [trip.name, trip.originName, trip.destinationName, trip.folder ?? ""] + trip.stops.map(\.name))
    }
}

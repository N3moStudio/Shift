import Combine
import Foundation

@MainActor
final class TripLibrary: ObservableObject {
    @Published private(set) var trips: [SavedTrip] = []
    @Published private(set) var revisions: [TripRevision] = []
    @Published var error: String?
    private(set) var lastSavedID: UUID?
    private var loadFailed = false
    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Locus", isDirectory: true).appendingPathComponent("Trips.json")
    }

    init() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= TripLibraryDocument.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            let loaded = try TripLibraryDocument.decode(Data(contentsOf: file))
            trips = loaded.trips
            revisions = loaded.revisions
        } catch {
            loadFailed = true
            self.error = "Saved trips could not be read. The original file was kept; no trips will be overwritten."
        }
    }

    @discardableResult
    func save(route: PlannedRoute, name: String, mode: TravelMode, speed: Double, smooth: Bool, arrival: ArrivalChoice = .stay, replacingID: UUID? = nil) -> Bool {
        let replacingIndex = trips.firstIndex { $0.id == replacingID }
        guard trips.count < 50 || replacingIndex != nil else { error = "You have 50 saved trips. Remove one before saving another."; return false }
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        var trip = SavedTrip(name: title.isEmpty ? String(route.destination.name.prefix(120)) : title,
            mode: mode, speedMPH: mode.clampedSpeedMPH(speed), smoothMovement: smooth,
            originName: route.origin.name, destinationName: route.destination.name, points: route.track.points,
            source: route.source, instructions: route.instructions, stops: route.stops, calculatedAt: route.calculatedAt,
            travelSections: route.travelSections.isEmpty ? nil : route.travelSections, arrival: arrival)
        guard trip.isValid else { error = "This trip could not be saved. Check the route and stops."; return false }
        if let replacingIndex {
            trip.id = trips[replacingIndex].id
            trip.folder = trips[replacingIndex].folder
            var updated = trips
            updated[replacingIndex] = trip
            let saved = write(updated)
            if saved { lastSavedID = trip.id }
            return saved
        }
        let saved = write([trip] + trips)
        if saved { lastSavedID = trip.id }
        return saved
    }

    func rename(_ trip: SavedTrip, to name: String) {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !title.isEmpty, let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        var updated = trips
        updated[index].name = title
        _ = write(updated, reason: .name)
    }
    func renameLinkedPlace(_ place: SavedPlace, to text: String) {
        let name = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !name.isEmpty else { return }
        let point = RoutePoint(place.coordinate)
        var updated = trips
        for i in updated.indices {
            guard let track = RouteTrack(updated[i].points) else { continue }
            if updated[i].originName == place.name, track.point(at: 0).distance(to: point) <= 5 { updated[i].originName = name }
            if updated[i].destinationName == place.name, track.point(at: track.length).distance(to: point) <= 5 { updated[i].destinationName = name }
            for j in updated[i].stops.indices {
                if updated[i].stops[j].name == place.name, track.point(at: updated[i].stops[j].metres).distance(to: point) <= 5 {
                    updated[i].stops[j].name = name
                }
            }
        }
        if updated != trips { _ = write(updated, reason: .labels) }
    }

    func remove(_ trip: SavedTrip) {
        guard let current = trips.first(where: { $0.id == trip.id }) else { return }
        let bin = RecentlyDeletedStore.shared
        guard let deletedID = bin.keep(.trip(current)) else { error = bin.error; return }
        if !write(trips.filter { $0.id != trip.id }) { _ = bin.remove(deletedID) }
    }
    @discardableResult
    func replaceDrawnPath(_ trip: SavedTrip, points: [RoutePoint]) -> Bool {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }), trips[index] == trip,
              let changed = DrawnPathEdit.replacing(trip, with: points) else {
            error = "Couldn't save this edit. Reopen the saved trip and check its path."; return false
        }
        var updated = trips
        updated[index] = changed
        return write(updated, reason: .path)
    }

    /// Called only after the user confirms clearing explicitly saved trips.
    @discardableResult
    func clearAll() -> Bool {
        guard RecentlyDeletedStore.shared.clear(kind: "Saved trip") else { error = RecentlyDeletedStore.shared.error; return false }
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            trips = []
            revisions = []
            loadFailed = false
            error = nil
            return true
        } catch {
            self.error = "Saved trips could not be deleted. Please try again."
            return false
        }
    }

    @discardableResult
    func merge(_ incoming: [SavedTrip]) throws -> Bool {
        let merged = try LibraryMerge.trips(local: trips, incoming: incoming)
        guard merged.allSatisfy(\.isValid) else { throw BackupError.invalid }
        return write(merged)
    }
    func move(_ trip: SavedTrip, folder: String) {
        guard let index = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        var updated = trips
        let value = String(folder.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        updated[index].folder = value.isEmpty ? nil : value
        _ = write(updated, reason: .folder)
    }
    func duplicate(_ trip: SavedTrip) -> SavedTrip? {
        guard trips.count < 50 else { error = "Remove a trip before making another copy."; return nil }
        guard let current = trips.first(where: { $0.id == trip.id }) else { error = "This trip is no longer saved."; return nil }
        let copy = current.duplicated(existingNames: Set(trips.map(\.name)))
        guard write([copy] + trips) else { return nil }
        lastSavedID = copy.id
        DeveloperLogStore.shared.record("saved_trip_duplicated", ["source": current.id.uuidString, "copy": copy.id.uuidString])
        return copy
    }
    func history(for tripID: UUID) -> [TripRevision] { revisions.filter { $0.trip.id == tripID } }

    @discardableResult
    func restoreRevision(_ revisionID: UUID, for tripID: UUID, expected: SavedTrip) -> Bool {
        do {
            let document = TripLibraryDocument(trips: trips, revisions: revisions)
            let restored = try document.restoring(revisionID, tripID: tripID, expected: expected)
            guard persist(restored) else { return false }
            DeveloperLogStore.shared.record("saved_trip_version_restored", ["trip": tripID.uuidString, "revision": revisionID.uuidString])
            return true
        } catch {
            self.error = "The trip changed or that version is no longer available. Reopen its history and try again."
            return false
        }
    }

    @discardableResult
    func clearHistory(for tripID: UUID) -> Bool {
        persist(TripLibraryDocument(trips: trips, revisions: revisions.filter { $0.trip.id != tripID }))
    }

    private func write(_ updated: [SavedTrip], reason: TripEditReason = .route) -> Bool {
        do {
            let document = TripLibraryDocument(trips: trips, revisions: revisions)
            return persist(try document.updating(to: updated, reason: reason))
        } catch { self.error = "Could not save this trip and its earlier version. Your saved trips were kept."; return false }
    }

    private func persist(_ document: TripLibraryDocument) -> Bool {
        guard !loadFailed else { error = "The saved-trip file could not be read, so it has not been overwritten."; return false }
        do {
            let data = try document.encoded()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            trips = document.trips
            revisions = document.revisions
            error = nil
            return true
        } catch { self.error = "Could not save trips and edit history. Your original file was kept. Free storage or clear earlier versions and try again."; return false }
    }
}

extension SavedTrip {
    var plannedRoute: PlannedRoute? {
        guard isValid, let track = RouteTrack(points), let first = points.first, let last = points.last else { return nil }
        return PlannedRoute(name: name, origin: RoutePlace(name: originName, coordinate: first.coordinate),
            destination: RoutePlace(name: destinationName, coordinate: last.coordinate), coordinates: points.map(\.coordinate),
            track: track, source: source, distance: track.length,
            notices: ["Saved path. Directions are not recalculated when you open this trip."],
            appleTravelTime: nil, instructions: instructions, calculatedAt: calculatedAt, stops: stops, storedMode: mode,
            travelSections: travelSections ?? [])
    }
}

extension PlannedRoute {
    func savedTrip(name: String, mode: TravelMode, speed: Double, smooth: Bool, arrival: ArrivalChoice) -> SavedTrip {
        SavedTrip(name: String(name.prefix(120)), mode: mode, speedMPH: mode.clampedSpeedMPH(speed),
            smoothMovement: smooth, originName: origin.name, destinationName: destination.name,
            points: track.points, source: source, instructions: instructions, stops: stops,
            calculatedAt: calculatedAt, travelSections: travelSections.isEmpty ? nil : travelSections, arrival: arrival)
    }
}

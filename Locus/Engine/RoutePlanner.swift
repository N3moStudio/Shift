import Combine
import MapKit

struct PreparedRoute: Identifiable {
    let route: PlannedRoute
    let mode: TravelMode
    let speedMPH: Double
    let smoothMovement: Bool
    var arrival: ArrivalChoice = .stay
    var editingTripID: UUID? = nil
    var continuationNote: String? = nil
    let waypoints: [TripWaypoint]
    let usesStoredPath: Bool
    let sectionChoices: [UUID: RouteLegChoice]
    var id: UUID { route.id }
}

@MainActor
final class RoutePlanner: ObservableObject {
    @Published private(set) var preparedRoute: PreparedRoute?
    @Published var editingTripID: UUID?
    private var draftContinuationNote: String?
    @Published var draftArrival: ArrivalChoice = .stay
    @Published private(set) var continuationLoading = false
    @Published var draftMode: TravelMode = .walk
    @Published var draftSpeedMPH = 3.0
    @Published var draftSmoothMovement = false
    private var draftSettingsInitialized = false
    @Published private(set) var origin: RoutePlace?
    @Published private(set) var destination: RoutePlace?
    @Published private(set) var alternatives: [PlannedRoute] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var isPresented = false
    @Published var isDrawing = false
    @Published private(set) var waypoints: [TripWaypoint] = []
    @Published private(set) var usesStoredPath = false
    @Published private(set) var sectionChoices: [UUID: RouteLegChoice] = [:]
    @Published var preferWalkingPaths = UserDefaults.standard.bool(forKey: "locus.preferWalkingPaths") {
        didSet { UserDefaults.standard.set(preferWalkingPaths, forKey: "locus.preferWalkingPaths") }
    }
    private var generation = UUID()
    private var task: Task<Void, Never>?

    var selectedRoute: PlannedRoute? { alternatives.first { $0.id == selectedID } }

    func initializeDraftIfNeeded(mode: TravelMode, speedMPH: Double, smoothMovement: Bool) {
        guard !draftSettingsInitialized else { return }
        draftMode = mode
        draftSpeedMPH = mode.clampedSpeedMPH(speedMPH)
        draftSmoothMovement = smoothMovement
        draftSettingsInitialized = true
    }
    @discardableResult
    func prepareSelectedRoute(mode: TravelMode, speedMPH: Double, smoothMovement: Bool) -> Bool {
        guard !isLoading, let route = selectedRoute, route.supports(mode) else { return false }
        preparedRoute = PreparedRoute(route: route, mode: mode, speedMPH: mode.clampedSpeedMPH(speedMPH), smoothMovement: smoothMovement,
            arrival: draftArrival, editingTripID: editingTripID, continuationNote: draftContinuationNote,
            waypoints: waypoints, usesStoredPath: usesStoredPath, sectionChoices: sectionChoices)
        return true
    }
    func discardPreparedRoute() { preparedRoute = nil }
    func previewContinuation(choice: ArrivalChoice, session: SpoofSession) {
        guard choice != .stay, !continuationLoading, session.journey?.state == .arrived,
              let original = session.activeRoute, let coordinate = session.simulated else { return }
        cancel()
        continuationLoading = true
        error = nil
        let token = generation
        let mode = session.travelMode
        let speed = session.speedMPH(for: mode)
        let smooth = session.smoothMovement
        let preferWalking = preferWalkingPaths
        task = Task { [weak self, weak session] in
            do {
                let route = try await RouteContinuation.make(original: original, from: coordinate,
                    choice: choice, mode: mode, speed: speed, preferWalking: preferWalking)
                guard let self, let session, !Task.isCancelled, generation == token,
                      session.activeRoute?.id == original.id, session.journey?.state == .arrived else {
                    if let self, self.generation == token { self.continuationLoading = false; self.task = nil }
                    return
                }
                session.stopRoute()
                guard session.journey == nil else { self.continuationLoading = false; self.task = nil; return }
                preparedRoute = PreparedRoute(route: route, mode: mode, speedMPH: speed, smoothMovement: smooth,
                    continuationNote: choice == .repeatTrip ? "Includes the path back to the start, then one repeat. Review the map before starting." : "New directions back to the start. Review the map before starting.",
                    waypoints: [], usesStoredPath: true, sectionChoices: [:])
                continuationLoading = false
                task = nil
                isPresented = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.continuationLoading = false
                self.task = nil
                self.error = error.localizedDescription
            }
        }
    }
    func editPreparedRoute() {
        guard let preparedRoute else { return }
        cancel()
        let route = preparedRoute.route
        origin = route.origin
        destination = route.destination
        alternatives = [route]
        selectedID = route.id
        waypoints = preparedRoute.waypoints
        sectionChoices = preparedRoute.sectionChoices
        usesStoredPath = preparedRoute.usesStoredPath
        editingTripID = preparedRoute.editingTripID
        draftContinuationNote = preparedRoute.continuationNote
        draftArrival = preparedRoute.arrival
        draftMode = preparedRoute.mode
        draftSpeedMPH = preparedRoute.speedMPH
        draftSmoothMovement = preparedRoute.smoothMovement
        draftSettingsInitialized = true
        error = nil
        isPresented = true
    }

    func plan(to place: RoutePlace, defaultOrigin: RoutePlace?, mode: TravelMode) {
        destination = place
        origin = defaultOrigin ?? origin
        isPresented = true
        rebuild(mode: mode)
    }
    func setOrigin(_ place: RoutePlace, mode: TravelMode) {
        origin = place
        rebuild(mode: mode)
    }
    func setDestination(_ place: RoutePlace, defaultOrigin: RoutePlace?, mode: TravelMode) {
        destination = place
        if origin == nil { origin = defaultOrigin }
        rebuild(mode: mode)
    }
    func swap(mode: TravelMode) {
        syncPathStops()
        usesStoredPath = false
        waypoints.reverse()
        let previous = origin
        origin = destination
        destination = previous
        rebuild(mode: mode)
    }
    func modeChanged(_ mode: TravelMode) {
        guard isPresented else { return }
        if usesStoredPath {
            if hasSectionSettings { return }
            for index in alternatives.indices { alternatives[index].storedMode = mode }
            return
        }
        if selectedRoute?.source.isAutomatic == false { return }
        rebuild(mode: mode)
    }
    func choose(_ route: PlannedRoute) {
        selectedID = route.id
    }

    /// Dismissing an unaccepted draft clears only that draft. A route explicitly
    /// staged with Show route stays on the map until Start or Discard.
    func discardDraft() {
        cancel()
        origin = nil
        destination = nil
        alternatives = []
        selectedID = nil
        error = nil
        waypoints = []
        sectionChoices = [:]
        usesStoredPath = false
        draftSettingsInitialized = false
        draftArrival = .stay
        editingTripID = nil
        draftContinuationNote = nil
    }
    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        continuationLoading = false
    }
    func rebuild(mode: TravelMode) {
        cancel()
        syncPathStops()
        usesStoredPath = false
        error = nil
        alternatives = []
        selectedID = nil
        guard let origin, let destination else { return }
        let token = generation
        let stops = waypoints
        let preferWalking = preferWalkingPaths
        let choices = sectionChoices
        let defaultSpeed = mode.clampedSpeedMPH(draftSpeedMPH)
        isLoading = true
        task = Task { [weak self] in
            do {
                let routes = try await RouteBuilder.itinerary(from: origin, to: destination, via: stops,
                                                              mode: mode, preferWalkingPaths: preferWalking, legChoices: choices, defaultSpeedMPH: defaultSpeed)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.alternatives = routes
                self.selectedID = routes.first?.id
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.error = error.localizedDescription
                self.isLoading = false
                self.task = nil
            }
        }
    }
    func useCustom(_ coordinates: [CLLocationCoordinate2D], source: RoutePathSource) {
        guard let route = RouteBuilder.customRoute(coordinates, source: source) else {
            error = "Choose at least two different, valid points for the path."
            return
        }
        cancel()
        waypoints = []
        editingTripID = nil
        sectionChoices = [:]
        usesStoredPath = true
        origin = route.origin
        destination = route.destination
        alternatives = [route]
        selectedID = route.id
        error = nil
        isPresented = true
    }

    func useSaved(_ trip: SavedTrip) {
        guard let route = trip.plannedRoute else { error = "The saved trip is invalid."; return }
        cancel()
        editingTripID = trip.id
        draftArrival = trip.arrival ?? .stay
        draftMode = trip.mode
        draftSpeedMPH = trip.speedMPH
        draftSmoothMovement = trip.smoothMovement
        draftSettingsInitialized = true
        origin = route.origin
        destination = route.destination
        alternatives = [route]
        selectedID = route.id
        waypoints = route.stops.map { TripWaypoint(id: $0.id, name: $0.name, point: route.track.point(at: $0.metres), waitSeconds: $0.waitSeconds) }
        usesStoredPath = true
        sectionChoices = Dictionary(uniqueKeysWithValues: route.travelSections.map { ($0.id, RouteLegChoice(mode: $0.mode, speedMPH: $0.speedMPH)) })
        error = nil
        isPresented = true
    }

    func addWaypoint(_ place: RoutePlace, mode: TravelMode, speedMPH: Double? = nil) {
        guard waypoints.count < 8 else { return }
        let waypoint = TripWaypoint(name: place.name, point: RoutePoint(place.coordinate))
        if hasSectionSettings { sectionChoices[waypoint.id] = RouteLegChoice(mode: mode, speedMPH: mode.clampedSpeedMPH(speedMPH ?? mode.defaultSpeedMPH)) }
        waypoints.append(waypoint)
        rebuild(mode: mode)
    }
    func removeWaypoint(_ id: UUID, mode: TravelMode) {
        waypoints.removeAll { $0.id == id }
        sectionChoices.removeValue(forKey: id)
        rebuild(mode: mode)
    }
    func moveWaypoint(_ id: UUID, offset: Int, mode: TravelMode) {
        guard let index = waypoints.firstIndex(where: { $0.id == id }), waypoints.indices.contains(index + offset) else { return }
        waypoints.swapAt(index, index + offset)
        rebuild(mode: mode)
    }
    func setWait(_ id: UUID, seconds: Double) {
        guard seconds.isFinite else { return }
        let value = min(3600, max(0, seconds))
        if let index = waypoints.firstIndex(where: { $0.id == id }) { waypoints[index].waitSeconds = value }
        for index in alternatives.indices {
            if let stop = alternatives[index].stops.firstIndex(where: { $0.id == id }) { alternatives[index].stops[stop].waitSeconds = value }
        }
    }
    func setAllWaits(seconds: Double) {
        guard !isLoading, seconds.isFinite else { return }
        let value = StopDuration.normalized(seconds)
        waypoints = waypoints.map { var stop = $0; stop.waitSeconds = value; return stop }
        alternatives = alternatives.map { route in
            var updated = route
            updated.stops = route.stops.map { var stop = $0; stop.waitSeconds = value; return stop }
            return updated
        }
    }
    func addPathStop(name: String, fraction: Double, wait: Double) {
        guard let route = selectedRoute, route.stops.count < 20, fraction.isFinite, wait.isFinite else { return }
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let stop = RouteStop(name: title.isEmpty ? "Stop \(route.stops.count + 1)" : title,
            metres: min(1, max(0, fraction)) * route.track.length, waitSeconds: min(3600, max(0, wait)))
        guard let index = alternatives.firstIndex(where: { $0.id == route.id }) else { return }
        alternatives[index].stops.append(stop)
        alternatives[index].stops.sort { $0.metres < $1.metres }
        usesStoredPath = true
    }
    func removePathStop(_ id: UUID) {
        guard let index = alternatives.firstIndex(where: { $0.id == selectedID }) else { return }
        alternatives[index].stops.removeAll { $0.id == id }
        waypoints.removeAll { $0.id == id }
    }

    var hasSectionSettings: Bool { !sectionChoices.isEmpty }

    func setSectionSettings(_ enabled: Bool, mode: TravelMode, speedMPH: Double) {
        if usesStoredPath {
            guard !enabled else { return }
            sectionChoices = [:]
            for index in alternatives.indices {
                alternatives[index].travelSections = []
                alternatives[index].storedMode = mode
            }
            return
        }
        if enabled {
            let choice = RouteLegChoice(mode: mode, speedMPH: mode.clampedSpeedMPH(speedMPH))
            sectionChoices = Dictionary(uniqueKeysWithValues: (waypoints.map(\.id) + [RouteLegChoice.destinationID]).map { ($0, choice) })
        } else { sectionChoices = [:] }
        rebuild(mode: mode)
    }
    func setSectionChoice(_ choice: RouteLegChoice, for id: UUID, defaultMode: TravelMode) {
        guard !usesStoredPath, hasSectionSettings, choice.isValid else { return }
        sectionChoices[id] = choice
        rebuild(mode: defaultMode)
    }
    func applyMapEdit(origin start: RoutePoint, destination end: RoutePoint, stops: [TripWaypoint], mode: TravelMode, speedMPH: Double? = nil) {
        guard start.isValid, end.isValid, stops.count <= 20, stops.allSatisfy({ $0.point.isValid }),
              Set(stops.map(\.id)).count == stops.count else { return }
        cancel()
        let oldStart = origin, oldEnd = destination
        origin = RoutePlace(name: oldStart.map { RoutePoint($0.coordinate) == start ? $0.name : "Edited start" } ?? "Start", coordinate: start.coordinate)
        destination = RoutePlace(name: oldEnd.map { RoutePoint($0.coordinate) == end ? $0.name : "Edited destination" } ?? "Destination", coordinate: end.coordinate)
        waypoints = stops
        usesStoredPath = false
        let allowed = Set(stops.map(\.id) + [RouteLegChoice.destinationID])
        sectionChoices = sectionChoices.filter { allowed.contains($0.key) }
        if hasSectionSettings {
            for id in allowed where sectionChoices[id] == nil {
                sectionChoices[id] = RouteLegChoice(mode: mode, speedMPH: mode.clampedSpeedMPH(speedMPH ?? mode.defaultSpeedMPH))
            }
        }
        rebuild(mode: mode)
    }

    var editableWaypoints: [TripWaypoint] {
        if usesStoredPath, let route = selectedRoute {
            return route.stops.map { TripWaypoint(id: $0.id, name: $0.name, point: route.track.point(at: $0.metres), waitSeconds: $0.waitSeconds) }
        }
        return waypoints
    }

    func applyPlaceEdits(_ places: [TripWaypoint], mode: TravelMode) {
        guard places.count >= 2, places.count <= 22, let start = places.first, let end = places.last,
              places.allSatisfy({ $0.point.isValid && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 && (0...3600).contains($0.waitSeconds) }),
              let route = selectedRoute else { return }
        let stops = Array(places.dropFirst().dropLast())
        let old = editableWaypoints
        let sameGeometry = RoutePoint(route.origin.coordinate) == start.point && RoutePoint(route.destination.coordinate) == end.point &&
            old.map(\.id) == stops.map(\.id) && zip(old, stops).allSatisfy { pair in pair.0.point == pair.1.point }
        origin = RoutePlace(name: start.name, coordinate: start.point.coordinate)
        destination = RoutePlace(name: end.name, coordinate: end.point.coordinate)
        if sameGeometry {
            waypoints = stops
            for index in alternatives.indices {
                alternatives[index].origin = RoutePlace(name: start.name, coordinate: start.point.coordinate)
                alternatives[index].destination = RoutePlace(name: end.name, coordinate: end.point.coordinate)
                for j in alternatives[index].stops.indices {
                    if let value = stops.first(where: { $0.id == alternatives[index].stops[j].id }) {
                        alternatives[index].stops[j].name = value.name
                        alternatives[index].stops[j].waitSeconds = value.waitSeconds
                    }
                }
            }
        } else {
            // Prevent syncPathStops from bringing the old positions back.
            usesStoredPath = false
            waypoints = stops
            let allowed = Set(stops.map(\.id) + [RouteLegChoice.destinationID])
            sectionChoices = sectionChoices.filter { allowed.contains($0.key) }
            rebuild(mode: mode)
        }
    }

    private func syncPathStops() {
        guard usesStoredPath, let route = selectedRoute else { return }
        waypoints = route.stops.map { TripWaypoint(id: $0.id, name: $0.name, point: route.track.point(at: $0.metres), waitSeconds: $0.waitSeconds) }
    }
}

extension Notification.Name {
    static let locusDrawRoute = Notification.Name("locus.drawRoute")
}

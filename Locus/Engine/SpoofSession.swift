import CoreLocation
import Combine
import Foundation
import MapKit
import UIKit
import UserNotifications

enum SpoofStatus: Equatable {
    case idle, connecting, active, reconnecting, stopping, unverified
    case dropped(String)

    var phase: SessionPhase {
        switch self {
        case .idle: return .idle
        case .connecting: return .connecting
        case .active: return .active
        case .reconnecting: return .reconnecting
        case .stopping: return .stopping
        case .unverified: return .unverified
        case .dropped: return .disconnected
        }
    }
    var label: String { phase.title }
    var isDropped: Bool { if case .dropped = self { return true }; return false }
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published private(set) var status: SpoofStatus = .idle {
        didSet {
            if status != oldValue { routeConnection.signal(); routeControls.signal() }
        }
    }
    @Published var pin: CLLocationCoordinate2D?
    @Published private(set) var pinIsPreview = false
    @Published private(set) var namedAreas: [NamedArea] = {
        guard let data = UserDefaults.standard.data(forKey: "locus.namedAreas"),
              let values = try? JSONDecoder().decode([NamedArea].self, from: data),
              values.count <= 100, values.allSatisfy(\.isValid) else { return [] }
        return values
    }()
    private var chosenNames: [SessionSpotName] = []
    @Published private(set) var activeSavedTripID: UUID?
    @Published private(set) var previewSpotName: SessionSpotName?
    @Published private(set) var sessionSpotName: SessionSpotName?
    private var pinSelectionID = UUID()
    @Published private(set) var deviceLocationFix: CLLocation?
    @Published private(set) var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var eBikeSpeedMPH = EBikeSpeed.defaultMPH {
        didSet { UserDefaults.standard.set(EBikeSpeed.clamped(eBikeSpeedMPH), forKey: EBikeSpeed.preferenceKey) }
    }
    @Published private var modeSpeeds = UserDefaults.standard.dictionary(forKey: "locus.modeSpeeds") as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(modeSpeeds, forKey: "locus.modeSpeeds") }
    }
    @Published private(set) var routeJumping = false
    @Published private(set) var routeRerouting = false
    @Published var smoothMovement = MovementDefaults.loadSmoothMovement(from: .standard) {
        didSet { UserDefaults.standard.set(smoothMovement, forKey: "locus.smoothMovement") }
    }
    private var motionSpeed = 0.0
    @Published private var measuredRouteSpeed = 0.0
    private var speedRevision = 0
    @Published private var usualSpeeds = UserDefaults.standard.dictionary(forKey: UsualSpeedRules.preferenceKey) as? [String: Double] ?? [:] {
        didSet { UserDefaults.standard.set(usualSpeeds, forKey: UsualSpeedRules.preferenceKey) }
    }
    private var pendingRouteTarget: Double?
    var currentRouteSpeed: Double {
        guard journey?.state == .moving, !routePaused, effectivePhase == .active else { return 0 }
        return measuredRouteSpeed
    }
    @Published private(set) var stopProgress = RouteStopProgress()
    @Published private(set) var jumpUndo: RouteJumpUndo?
    private var pendingSeek: (selection: AcceptedRouteSeek, wasPaused: Bool, restore: RouteJumpUndo?)? {
        didSet { routeControls.signal() }
    }
    private var waitRevision = 0
    private var rerouteTask: Task<Void, Never>?
    private var rerouteGeneration = UUID()
    @Published private(set) var routeActive = false
    @Published private(set) var routePaused = false {
        didSet { if routePaused != oldValue { routeControls.signal() } }
    }
    @Published private(set) var routeStopping = false
    @Published private(set) var routeSectionSettingsEnabled = false
    private var sectionSpeedOverrides: [UUID: Double] = [:]
    private var appliedSectionID: UUID?
    @Published private(set) var activeRoute: PlannedRoute?
    @Published private(set) var journey: JourneyProgress?
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var joystickActive = false
    @Published private(set) var lastConfirmedAt: Date?
    @Published private(set) var startedAt: Date?
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var notificationPermission = false
    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    let verification = LocationVerificationController()
    var remoteCheckSessionRequested: Bool { sessionRequested && !stopInFlight }
    let recovery = TripRecoveryStore()
    let reliability = ReliabilityRecorder()
    @Published private(set) var recoveryAvailable = false
    @Published var arrivalChoice: ArrivalChoice = .stay {
        didSet { saveTripCheckpoint(force: true) }
    }
    let preferences = SessionPreferences.shared
    let activity = SessionActivityController()
    private var sessionID = UUID()
    private var epoch = 0
    private var sessionRequested = false
    private var requiresClear = false
    private var locationMayRemainBeforeAttempt = false
    @Published private(set) var reopenedWithoutConnection = false
    private var sendInFlight = false {
        didSet { if sendInFlight != oldValue { routeConnection.signal() } }
    }
    private var activeWriteID: UUID?
    private var stopInFlight = false
    private var operationStartedAt: Date?
    private var lastAttemptAt = Date.distantPast
    private var lastActivityPublish = Date.distantPast
    private var warnedUnverified = false
    private var warnedFailure = false
    private var monitorTask: Task<Void, Never>?
    private var joystickTimer: Timer?
    private var joystickTick: (() -> Void)?
    private var routeTask: Task<Void, Never>?
    private let routeControls = RouteWakeSignal()
    private let routeConnection = RouteWakeSignal()
    private var routeWorkerID = UUID()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    // Camera changes don't publish session/UI updates or start a movement timer.
    private var joystickMapHeading: Double = 0
    private let locationKeeper = BackgroundKeepAlive()
    private var appActive = UIApplication.shared.applicationState == .active
    private var mapLocationNeeded = false
    private var sessionLocationKeepAlive = false
    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"
    private let unfinishedKey = "locus.unfinishedSession"

    init() {
        if let saved = UserDefaults.standard.object(forKey: EBikeSpeed.preferenceKey) as? Double {
            eBikeSpeedMPH = EBikeSpeed.clamped(saved)
        } else { eBikeSpeedMPH = UsualSpeedRules.value(for: .eBike, stored: usualSpeeds) }
        for mode in TravelMode.allCases where mode != .eBike && modeSpeeds[mode.rawValue] == nil {
            modeSpeeds[mode.rawValue] = UsualSpeedRules.value(for: mode, stored: usualSpeeds)
        }
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.loadRecents(retention: preferences.recentHistoryRetention, saveEnabled: preferences.saveRecentLocations)
        // Never adopt the old app process's green status after a crash/relaunch.
        if UserDefaults.standard.bool(forKey: unfinishedKey) {
            requiresClear = true
            reopenedWithoutConnection = true
            DeveloperLogStore.shared.record("unfinished_session_on_launch", ["meaning": "Previous location may remain; old process connection is unavailable."])
            status = .unverified
            recoveryAvailable = recovery.checkpoint != nil
        }
        locationKeeper.acceptDeviceFixes = !requiresClear
        locationKeeper.onDeviceLocation = { [weak self] fix in self?.deviceLocationFix = fix }
        SessionNotifications.shared.install()
        RemoteFindMyController.shared.attach(self)
        CompanionClient.shared.attach(self)
        SessionNotifications.shared.cancelReminder()
        activity.sync(id: sessionID, snapshot: nil)
    }

    func discardRecovery() {
        recoveryAvailable = false
        recovery.discard()
    }

    func resumeSavedTrip(pairing: PairingStore, wifiAvailable: Bool) -> Bool {
        guard recoveryAvailable, let saved = recovery.checkpoint, saved.isValid,
              let plan = saved.trip.plannedRoute, !isBusy, !routeActive, !stopInFlight else { return false }
        guard wifiAvailable, pairing.hasPairingFile else {
            lastError = "Connect to Wi-Fi, turn on LocalDevVPN, and check pairing before resuming."
            return false
        }
        cancelRoute(clearJourney: false)
        stopJoystick()
        travelMode = saved.trip.mode
        setSpeedMPH(saved.trip.speedMPH, for: saved.trip.mode)
        smoothMovement = saved.trip.smoothMovement
        arrivalChoice = saved.arrival
        beginSession()
        activeRoute = plan
        routeSectionSettingsEnabled = !plan.travelSections.isEmpty
        sectionSpeedOverrides = [:]
        appliedSectionID = nil
        journey = JourneyProgress(totalMetres: plan.track.length)
        journey?.confirmPosition(saved.metres)
        stopProgress = saved.stops
        applyPlannedSection(at: saved.metres)
        pinIsPreview = false
        previewSpotName = nil
        recoveryAvailable = false
        routeActive = true
        routePaused = false
        startRoutePlayback(plan, pairing: pairing, ticket: epoch, initialWrite: true, initialMetres: saved.metres)
        return true
    }

    private func saveTripCheckpoint(force: Bool = false) {
        guard recovery.shouldSave(force: force), sessionRequested, !stopInFlight, !routeStopping,
              let route = activeRoute, let progress = journey, progress.state != .arrived,
              let confirmedAt = lastConfirmedAt, let simulated,
              RoutePoint(simulated).distance(to: route.track.point(at: progress.travelledMetres)) < 0.1 else { return }
        let trip = route.savedTrip(name: route.name, mode: travelMode, speed: speedMPH(for: travelMode),
                                  smooth: smoothMovement, arrival: arrivalChoice)
        recovery.save(TripCheckpoint(trip: trip, metres: progress.travelledMetres, stops: stopProgress,
                                    confirmedAt: confirmedAt, savedAt: Date(), arrival: arrivalChoice))
    }

    var backupPreferences: BackupPreferences {
        BackupPreferences(usualSpeeds: usualSpeeds, glassPanel: preferences.glassPanel,
            appearance: preferences.appearance, smoothMovement: smoothMovement,
            preferWalkingPaths: UserDefaults.standard.bool(forKey: "locus.preferWalkingPaths"), shortcuts: preferences.panelShortcuts,
            display: BackupDisplayPreferences(liveActivities: preferences.liveActivities, hideLocation: preferences.hideLocation,
                hideIslandLocation: preferences.hideIslandLocation, lockScreenProgress: preferences.lockScreenProgress,
                islandProgress: preferences.islandProgress, islandTimer: preferences.islandTimer,
                connectionAlerts: preferences.connectionAlerts, reminderMinutes: preferences.reminderMinutes,
                saveRecentLocations: preferences.saveRecentLocations, recentHistoryRetention: preferences.recentHistoryRetention,
                mapStyle: mapStyleIndex, connectionCheckSeconds: preferences.connectionCheckSeconds,
                showFindMyStatus: preferences.showFindMyStatus, showLife360Status: preferences.showLife360Status), speedUnit: preferences.speedUnit)
    }
    func importLibraryPlaces(_ places: [BackupPlace], settings: BackupPreferences?) {
        favorites = places.map { SavedPlace(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, folder: $0.folder, icon: $0.icon, color: $0.color) }
        SavedPlace.save(favorites, key: favoritesKey)
        if let settings {
            usualSpeeds = settings.usualSpeeds
            preferences.glassPanel = settings.glassPanel
            preferences.appearance = settings.appearance
            if let unit = settings.speedUnit { preferences.speedUnit = unit }
            preferences.panelShortcuts = settings.shortcuts
            smoothMovement = settings.smoothMovement
            if let display = settings.display {
                preferences.liveActivities = display.liveActivities
                preferences.hideLocation = display.hideLocation
                preferences.hideIslandLocation = display.hideIslandLocation
                preferences.lockScreenProgress = display.lockScreenProgress
                preferences.islandProgress = display.islandProgress
                preferences.islandTimer = display.islandTimer
                if let show = display.showFindMyStatus { preferences.showFindMyStatus = show }
                if let show = display.showLife360Status { preferences.showLife360Status = show }
                preferences.connectionAlerts = display.connectionAlerts
                preferences.reminderMinutes = display.reminderMinutes
                if let seconds = display.connectionCheckSeconds { preferences.connectionCheckSeconds = seconds }
                preferences.saveRecentLocations = display.saveRecentLocations
                preferences.recentHistoryRetention = display.recentHistoryRetention
                mapStyleIndex = display.mapStyle
                refreshRecentHistory()
            }
            UserDefaults.standard.set(settings.preferWalkingPaths, forKey: "locus.preferWalkingPaths")
        }
    }
    func moveFavorite(_ place: SavedPlace, folder: String) {
        guard let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        let value = String(folder.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        favorites[index].folder = value.isEmpty ? nil : value
        SavedPlace.save(favorites, key: favoritesKey)
    }

    var hasSession: Bool { sessionRequested || requiresClear || stopInFlight }
    var statusTitle: String {
        if status.isDropped && !hasSession { return "Couldn’t start spoofing" }
        if isBusy { return effectivePhase.title }
        if reopenedWithoutConnection { return "Previous session needs a connection" }
        return effectivePhase.title
    }
    var stopButtonTitle: String {
        if stopInFlight { return "Stopping…" }
        return effectivePhase == .active ? "Stop spoofing" : "Try clearing location"
    }
    var recoveryExplanation: String {
        "Closing Shift fully ends its connection. Your iPhone may keep the last spoofed location, but Shift cannot move or clear it until a new connection works. If Wi-Fi isn’t available now, you can’t finish reconnecting yet. When you have Wi-Fi, connect LocalDevVPN and try clearing the location. Leaving Wi-Fi during an already working session is different: that connection may keep working."
    }
    var isSpoofing: Bool { sessionRequested && effectivePhase == .active }
    var effectivePhase: SessionPhase {
        if status == .active && !SessionTiming.isFresh(lastConfirmedAt, lifetime: connectionEvidenceLifetime) { return .unverified }
        return status.phase
    }
    /// Core Location can itself be simulated. This is a device-reported fix,
    /// never independent proof of the real GPS location.
    var realCoordinate: CLLocationCoordinate2D? { locationKeeper.lastKnownCoordinate }
    func rememberSavedTrip(_ id: UUID, routeID: UUID) {
        if activeRoute?.id == routeID { activeSavedTripID = id }
    }
    func setMapLocationNeeded(_ needed: Bool) {
        mapLocationNeeded = needed
        updateLocationTracking()
    }
    private func updateLocationTracking() {
        let demand = LocationTrackingDemand.resolve(appActive: appActive,
            mapVisible: mapLocationNeeded, sessionKeepsAlive: sessionLocationKeepAlive)
        locationKeeper.updateDemand(demand, appActive: appActive)
    }
    func refreshDeviceLocation() {
        guard !hasSession, UIApplication.shared.applicationState == .active else { return }
        locationKeeper.requestPreciseFix()
    }
    func cancelDeviceLocationRefresh() { locationKeeper.cancelPreciseFix() }
    func selectPin(_ coordinate: CLLocationCoordinate2D, name: String? = nil) {
        DeveloperLogStore.shared.record("pin_selected", ["latitude": String(coordinate.latitude), "longitude": String(coordinate.longitude), "name": name ?? ""])
        pin = coordinate
        pinIsPreview = true
        if let name { rememberPlaceName(name, at: coordinate) }
        previewSpotName = previewSpotName.flatMap { $0.point.distance(to: RoutePoint(coordinate)) <= 5 ? $0 : nil }
        pinSelectionID = UUID()
    }

    var namingContext: UUID { pinIsPreview ? pinSelectionID : sessionID }

    @discardableResult
    func nameSpot(_ text: String, at point: RoutePoint, preview: Bool, context: UUID) -> Bool {
        if preview {
            guard pinIsPreview, context == pinSelectionID, let pin, RoutePoint(pin) == point else { return false }
            previewSpotName = SessionSpotName(text, at: point)
        } else {
            guard hasSession, !stopInFlight, context == sessionID else { return false }
            sessionSpotName = SessionSpotName(text, at: point)
            publishActivity(force: true)
        }
        return true
    }

    var activityPlaceLabel: String? {
        guard let simulated else { return nil }
        if let name = placeName(at: simulated) { return name }
        if let route = activeRoute {
            let destination = Self.isGenericFavoriteName(route.destination.name) ? "selected destination" : route.destination.name
            return journey?.state == .arrived ? destination : "Route to \(destination)"
        }
        let name = suggestedFavoriteName(for: simulated)
        return Self.isGenericFavoriteName(name) ? "Selected location" : name
    }

    var defaultRouteOrigin: RoutePlace? {
        if hasSession { return simulated.map { RoutePlace(name: placeName(at: $0) ?? "Current simulated location", coordinate: $0) } }
        if let fix = deviceLocationFix, Date().timeIntervalSince(fix.timestamp) < 30 {
            return RoutePlace(name: "Device location", coordinate: fix.coordinate)
        }
        return nil
    }

    var journeyRemainingSeconds: TimeInterval? {
        guard let journey, let route = activeRoute, effectivePhase == .active,
              journey.state == .moving || journey.state == .waiting else { return nil }
        let moving = routeSectionSettingsEnabled
            ? RouteTravelSection.remainingSeconds(route.travelSections, from: journey.travelledMetres, overrides: sectionSpeedOverrides)
            : journey.remainingMetres / cruiseSpeed(for: travelMode)
        return moving + stopProgress.remainingWait(in: route.stops)
    }

    var currentStop: RouteStop? { activeRoute?.stops.first { $0.id == stopProgress.currentID } }
    func continueFromStop() {
        DeveloperLogStore.shared.record("continue_from_stop_tapped")
        guard currentStop != nil, canEditRouteMovement, isSpoofing else { return }
        waitRevision += 1
        stopProgress.finish()
        journey?.state = routePaused ? .paused : .moving
        publishActivity(force: true)
    }
    var canUndoJump: Bool { jumpUndo?.isValid(routeID: activeRoute?.id, now: Date()) == true && canEditRouteMovement && isSpoofing }
    func undoRouteJump(pairing: PairingStore) {
        guard canUndoJump, let undo = jumpUndo, let plan = activeRoute, pairing.hasPairingFile,
              let accepted = AcceptedRouteSeek(RouteSeek(routeID: undo.routeID, metres: undo.metres, expiresAt: undo.expiresAt),
                                               routeID: plan.id, now: Date()) else { return }
        pendingSeek = (accepted, undo.wasPaused, undo)
        routeJumping = true
        journey?.state = .seeking
        routeActive = true
        if routeTask == nil { startRoutePlayback(plan, pairing: pairing, ticket: epoch, initialWrite: false) }
        publishActivity(force: true)
    }

    var currentRouteInstruction: RouteInstruction? {
        guard let activeRoute, let journey, let index = journey.instructionIndex(in: activeRoute.instructions) else { return nil }
        return activeRoute.instructions[index]
    }

    @discardableResult
    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) -> Bool {
        DeveloperLogStore.shared.record("teleport_tapped", ["latitude": String(coordinate.latitude), "longitude": String(coordinate.longitude)])
        guard !isBusy, !stopInFlight else {
            lastError = "A location command is already pending. Wait for it to finish or tap Stop spoofing."
            return false
        }
        guard pairing.hasPairingFile else {
            lastError = "Pair this iPhone in Settings before starting a session."
            return false
        }
        let selectedName = pinIsPreview && pin.map({ RoutePoint($0) == RoutePoint(coordinate) }) == true ? previewSpotName : nil
        cancelRoute()
        stopJoystick()
        pin = coordinate
        pinIsPreview = false
        previewSpotName = nil
        beginSession()
        let ticket = epoch
        Task {
            // One explicit command may wait behind a keep-alive. Advancing the
            // epoch above prevents that old write from changing the new UI.
            while sendInFlight, ticket == epoch, sessionRequested {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
            guard ticket == epoch, sessionRequested else { return }
            _ = await apply(coordinate, pairing: pairing, markRecent: true, ticket: ticket, confirmedName: selectedName)
        }
        return true
    }

    func retry(pairing: PairingStore) {
        DeveloperLogStore.shared.record("retry_tapped", ["reopened": String(reopenedWithoutConnection)])
        if let plan = activeRoute, let progress = journey {
            guard pairing.hasPairingFile, !isBusy, !stopInFlight else {
                lastError = "Check pairing and wait for the pending command before retrying."
                return
            }
            // Retain the selected path and completed/waiting stops after a
            // connection failure. A retry never resumes travel by itself.
            cancelRoute(clearJourney: false)
            stopJoystick()
            beginSession()
            routeActive = true
            routePaused = true
            journey?.state = .paused
            startRoutePlayback(plan, pairing: pairing, ticket: epoch, initialWrite: true,
                               initialMetres: progress.travelledMetres)
            return
        }
        guard let coordinate = simulated ?? pin else {
            lastError = "The previous connection ended when Shift closed. When Wi-Fi is available, connect LocalDevVPN and use Try clearing location. Until then, Shift cannot confirm or change the previous location."
            return
        }
        teleport(to: coordinate, pairing: pairing)
    }

    func stop(pairing: PairingStore) {
        DeveloperLogStore.shared.record("stop_tapped", ["phase": effectivePhase.rawValue, "reopened": String(reopenedWithoutConnection)])
        guard !stopInFlight else { return }
        epoch += 1 // Any late set result now belongs to an obsolete operation.
        let ticket = epoch
        verification.reset()
        sessionRequested = false
        requiresClear = true
        RemoteFindMyController.shared.stop()
        CompanionClient.shared.cancel()
        stopInFlight = true
        cancelRoute()
        stopJoystick()
        isBusy = true
        operationStartedAt = Date()
        status = .stopping
        publishActivity(force: true)
        startMonitor(pairing: pairing)
        SessionNotifications.shared.cancelReminder()
        Task {
            // Uses the same serial engine queue: an in-flight set finishes before
            // clear. No set is permitted to be queued after this stop request.
            let commandStart = Date()
            DeveloperLogStore.shared.record("clear_requested", ["operation": String(ticket)])
            let result = await LocationEngine.clear(pairingPath: pairing.pairingPath, deviceIP: TunnelConfig.targetIP)
            var details = ["operation": String(ticket), "duration_ms": String(Int(Date().timeIntervalSince(commandStart) * 1000))]
            switch result {
            case .success: details["result"] = "accepted"
            case .failure(let error): details["result"] = "failed"; details["stage"] = String(describing: error)
            }
            DeveloperLogStore.shared.record("clear_result", details)
            DeveloperLogStore.shared.maintenance(flush: true)
            guard ticket == epoch else { return }
            sendInFlight = false
            activeWriteID = nil
            stopInFlight = false
            isBusy = false
            operationStartedAt = nil
            endBackground()
            sessionLocationKeepAlive = false
            updateLocationTracking()
            switch result {
            case .success:
                reliability.finish()
                requiresClear = false
                reopenedWithoutConnection = false
                sessionSpotName = nil
                // Do not reuse a fix collected while simulation was active.
                locationKeeper.acceptDeviceFixes = true
                locationKeeper.minimumDeviceFixDate = Date()
                simulated = nil
                lastConfirmedAt = nil
                startedAt = nil
                status = .idle
                lastError = nil
                UserDefaults.standard.set(false, forKey: unfinishedKey)
                monitorTask?.cancel()
                monitorTask = nil
            case .failure(let error):
                let message = "Shift could not clear the last location. It may still be set. A new connection needs Wi-Fi and LocalDevVPN; if Wi-Fi isn’t available now, try clearing it when you can connect again. Shift won’t say it stopped until the clear command succeeds. " + error.localizedDescription
                status = .unverified
                lastError = message
                warn(title: "Shift could not confirm Stop", message: message)
            }
            publishActivity(force: true)
        }
    }

    @discardableResult
    func startJoystick(pairing: PairingStore) -> String? {
        DeveloperLogStore.shared.record("joystick_tapped")
        let access = JoystickAccess.check(sessionRequested: sessionRequested, hasLocation: simulated != nil,
                                          phase: effectivePhase, hasRoute: journey != nil, isBusy: isBusy)
        guard access == .ready else { return access.message }
        guard pairing.hasPairingFile else { return "Pair this iPhone in Settings before using the joystick." }
        // Reuse the confirmed session. No teleport, initial write, or route
        // cancellation is allowed just because the joystick was opened.
        let ticket = epoch
        joystickVector = .zero
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = nil
        joystickTick = { [weak self] in
            Task { @MainActor in await self?.tickJoystick(pairing: pairing, ticket: ticket) }
        }
        return nil
    }

    func updateJoystickMapHeading(_ heading: Double) {
        guard heading.isFinite else { return }
        joystickMapHeading = heading.truncatingRemainder(dividingBy: 360)
    }

    func updateJoystick(vector: CGVector) {
        guard joystickActive else { return }
        guard vector.dx.isFinite, vector.dy.isFinite else { updateJoystick(vector: .zero); return }
        joystickVector = vector
        if hypot(vector.dx, vector.dy) > 0.08 {
            guard joystickTimer == nil else { return }
            joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.joystickTick?() }
            }
        } else {
            joystickTimer?.invalidate()
            joystickTimer = nil
        }
    }
    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
        joystickTick = nil
    }

    @discardableResult
    func startPreparedRoute(_ prepared: PreparedRoute, pairing: PairingStore) -> Bool {
        DeveloperLogStore.shared.record("start_route_tapped")
        guard pairing.hasPairingFile else {
            lastError = "Pair this iPhone in Settings before starting a route."
            return false
        }
        guard !isBusy, !stopInFlight, !routeStopping, !routeActive,
              prepared.route.supports(prepared.mode) else {
            lastError = "Wait for the current operation to finish before starting this route."
            return false
        }
        // This explicit second Start is the first point at which a draft can
        // change the current session's mode, speed, joystick, or location.
        changeTravelMode(prepared.mode, keepCurrentPath: true)
        setSpeedMPH(prepared.speedMPH, for: prepared.mode)
        smoothMovement = prepared.smoothMovement
        arrivalChoice = prepared.arrival
        let started = followRoute(prepared.route, pairing: pairing)
        if started { activeSavedTripID = prepared.editingTripID }
        return started
    }

    @discardableResult
    func followRoute(_ plan: PlannedRoute, pairing: PairingStore) -> Bool {
        guard pairing.hasPairingFile, plan.supports(travelMode), !isBusy,
              !stopInFlight, !routeStopping, !routeActive else { return false }
        cancelRoute()
        stopJoystick()
        beginSession()
        activeRoute = plan
        routeSectionSettingsEnabled = !plan.travelSections.isEmpty
        sectionSpeedOverrides = [:]
        appliedSectionID = nil
        pinIsPreview = false
        previewSpotName = nil
        journey = JourneyProgress(totalMetres: plan.track.length)
        applyPlannedSection(at: 0)
        stopProgress = RouteStopProgress()
        motionSpeed = 0
        routeActive = true
        startRoutePlayback(plan, pairing: pairing, ticket: epoch, initialWrite: true)
        return true
    }

    private func startRoutePlayback(_ plan: PlannedRoute, pairing: PairingStore, ticket: Int,
                                    initialWrite: Bool, initialMetres: Double = 0) {
        let motion = RouteMotion(track: plan.track)
        let workerID = UUID()
        routeWorkerID = workerID
        routeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var needsInitialWrite = initialWrite
            var clock = RoutePlaybackClock(now: ProcessInfo.processInfo.systemUptime)
            var lastMovementConfirmation = ProcessInfo.processInfo.systemUptime
            var samples = RouteSpeedSamples()
            var sampledRevision = speedRevision
            @MainActor func resetMovementClock() {
                let now = ProcessInfo.processInfo.systemUptime
                clock.reset(now: now)
                lastMovementConfirmation = now
                samples.reset()
                if self.measuredRouteSpeed != 0 { self.measuredRouteSpeed = 0 }
            }
            defer {
                // Cancelling an old worker cannot tear down a replacement in
                // the same session (for example an accepted jump after arrival).
                if ticket == self.epoch, workerID == self.routeWorkerID {
                    let wasStopping = self.routeStopping
                    self.routeActive = false
                    self.routePaused = false
                    self.routeStopping = false
                    self.routeJumping = false
                    self.pendingSeek = nil
                    self.motionSpeed = 0
                    self.routeTask = nil
                    if wasStopping {
                        self.activeRoute = nil
                        self.journey = nil
                        self.routeSectionSettingsEnabled = false
                        self.sectionSpeedOverrides = [:]
                        self.appliedSectionID = nil
                    } else if let state = self.journey?.state, [.moving, .waiting, .paused, .pausing, .seeking].contains(state) {
                        self.journey?.state = .interrupted
                    }
                    self.publishActivity(force: true)
                }
            }
            while !Task.isCancelled, ticket == epoch, workerID == routeWorkerID, !status.isDropped {
                let connectionRevision = routeConnection.revision
                let controlRevision = routeControls.revision
                if sendInFlight {
                    await routeConnection.wait(after: connectionRevision)
                    continue
                }
                if needsInitialWrite {
                    let result = await sendRoutePoint(at: initialMetres, plan: plan, pairing: pairing, ticket: ticket)
                    if result == .busy { continue }
                    guard result == .sent, !Task.isCancelled, ticket == epoch, workerID == routeWorkerID else { return }
                    needsInitialWrite = false
                    resetMovementClock()
                    pushNamedRecent(name: plan.destination.name, coordinate: plan.destination.coordinate)
                    continue
                }
                if effectivePhase != .active {
                    resetMovementClock()
                    if motionSpeed != 0 { motionSpeed = 0 }
                    await routeConnection.wait(after: connectionRevision)
                    guard !Task.isCancelled, ticket == epoch, workerID == routeWorkerID else { return }
                    resetMovementClock()
                    continue
                }
                if let seek = pendingSeek {
                    guard seek.selection.belongs(to: activeRoute?.id) else { return }
                    let target = min(plan.track.length, max(0, seek.selection.metres))
                    let previousPosition = journey?.travelledMetres ?? 0
                    let previousStops = stopProgress
                    let result = await sendRoutePoint(at: target, plan: plan, pairing: pairing, ticket: ticket)
                    if result == .busy { continue }
                    guard result == .sent, !Task.isCancelled, ticket == epoch, workerID == routeWorkerID else { return }
                    journey?.confirmPosition(target)
                    applyPlannedSection(at: target)
                    resetMovementClock()
                    motionSpeed = 0
                    waitRevision += 1
                    if let restore = seek.restore {
                        stopProgress = restore.stops
                        jumpUndo = nil
                    } else {
                        stopProgress.seek(to: target, stops: activeRoute?.stops ?? plan.stops)
                        jumpUndo = RouteJumpUndo(routeID: plan.id, metres: previousPosition, wasPaused: seek.wasPaused,
                            stops: previousStops, expiresAt: Date().addingTimeInterval(RouteJumpUndo.duration))
                    }
                    pendingSeek = nil
                    routeJumping = false
                    routePaused = seek.wasPaused
                    journey?.state = RouteRefreshPolicy.stateAfterPause(paused: routePaused, writeInFlight: false,
                                                                       waitingAtStop: stopProgress.currentID != nil)
                    publishActivity(force: true)
                    continue
                }
                guard let progress = journey else { return }
                if routePaused {
                    resetMovementClock()
                    if motionSpeed != 0 { motionSpeed = 0 }
                    if journey?.state != .paused { journey?.state = .paused; publishActivity(force: true) }
                    // Keep-alive writes use routeConnection, so they don't
                    // wake a paused route. Resume/seek/cancellation do.
                    await routeControls.wait(after: controlRevision)
                    guard !Task.isCancelled, ticket == epoch, workerID == routeWorkerID else { return }
                    resetMovementClock()
                    continue
                }
                if let next = stopProgress.next(in: activeRoute?.stops ?? plan.stops), next.metres <= progress.travelledMetres + 0.01 {
                    resetMovementClock()
                    if motionSpeed != 0 { motionSpeed = 0 }
                    if stopProgress.currentID != next.id { stopProgress.arrive(next) }
                    if stopProgress.currentID != nil {
                        if journey?.state != .waiting { journey?.state = .waiting }
                        publishActivity(force: false)
                        let revision = waitRevision
                        let before = ProcessInfo.processInfo.systemUptime
                        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                        let elapsed = ProcessInfo.processInfo.systemUptime - before
                        guard !Task.isCancelled, ticket == epoch, workerID == routeWorkerID else { return }
                        if !routePaused, pendingSeek == nil, effectivePhase == .active, revision == waitRevision, elapsed <= 1 {
                            stopProgress.tick(elapsed)
                        }
                    }
                    continue
                }
                if progress.remainingMetres <= 0.001 {
                    motionSpeed = 0
                    journey?.state = .arrived
                    discardRecovery()
                    publishActivity(force: true)
                    return
                }
                if journey?.state != .moving { journey?.state = .moving }
                let delay = clock.delay(now: ProcessInfo.processInfo.systemUptime)
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                }
                guard !Task.isCancelled, ticket == epoch, workerID == routeWorkerID, !status.isDropped else { return }
                // A pause, seek, speed/mode change, or heartbeat may have arrived
                // during the delay. Re-read state before choosing the next point.
                if routePaused || pendingSeek != nil || sendInFlight || effectivePhase != .active { continue }
                guard let current = journey else { return }
                applyPlannedSection(at: current.travelledMetres)
                let stopAt = min(stopProgress.next(in: activeRoute?.stops ?? plan.stops)?.metres ?? plan.track.length,
                                 currentPlannedSection?.endMetres ?? plan.track.length)
                let elapsed = clock.advance(now: ProcessInfo.processInfo.systemUptime)
                if sampledRevision != speedRevision {
                    samples.reset()
                    sampledRevision = speedRevision
                }
                let cruise = cruiseSpeed(for: travelMode)
                let desired = smoothMovement ? motion.target(cruise: cruise, position: current.travelledMetres, stopAt: stopAt, mode: travelMode) : cruise
                let movement = RouteMotion.step(speed: motionSpeed, target: desired,
                    remaining: max(0, stopAt - current.travelledMetres), mode: travelMode, smooth: smoothMovement, seconds: elapsed)
                let target = min(stopAt, current.travelledMetres + movement.metres)
                let result = await sendRoutePoint(at: target, plan: plan, pairing: pairing, ticket: ticket)
                if result == .busy { continue }
                guard result == .sent, !Task.isCancelled, ticket == epoch, workerID == routeWorkerID else { return }
                let confirmedAt = ProcessInfo.processInfo.systemUptime
                samples.append(metres: target - current.travelledMetres, seconds: confirmedAt - lastMovementConfirmation)
                lastMovementConfirmation = confirmedAt
                measuredRouteSpeed = routePaused ? 0 : samples.metresPerSecond
                journey?.confirmPosition(target)
                let confirmedSpeed = routePaused ? 0 : movement.speed
                if motionSpeed != confirmedSpeed { motionSpeed = confirmedSpeed }
                applyPlannedSection(at: target)
                publishActivity(force: false)
            }
        }
    }

    private func sendRoutePoint(at metres: Double, plan: PlannedRoute, pairing: PairingStore, ticket: Int) async -> CommandResult {
        pendingRouteTarget = metres
        defer { pendingRouteTarget = nil }
        return await apply(plan.track.point(at: metres).coordinate, pairing: pairing, markRecent: false, ticket: ticket)
    }

    var canAddRouteStop: Bool {
        routeActive && canEditRouteMovement && isSpoofing && activeRoute != nil && journey != nil
    }
    /// Returns an error without closing the editor when its chosen spot passed.
    func addRouteStop(routeID: UUID, name: String, fraction: Double, wait: Double) -> String? {
        guard let route = activeRoute, route.id == routeID, let progress = journey, canAddRouteStop else {
            return "This route is no longer ready for a new stop. Check the route and connection, then try again."
        }
        guard fraction.isFinite, (0...1).contains(fraction) else { return LiveRouteStopInsertion.Failure.invalid.message }
        let result = LiveRouteStopInsertion.make(name: name, metres: fraction * route.track.length, waitSeconds: wait,
            length: route.track.length, travelled: progress.travelledMetres, pendingMetres: pendingRouteTarget,
            existingCount: route.stops.count)
        switch result {
        case .failure(let error): return error.message
        case .success(let stop):
            activeRoute?.stops.append(stop)
            activeRoute?.stops.sort { $0.metres < $1.metres }
            publishActivity(force: true)
            return nil
        }
    }

    var canEditRouteMovement: Bool { !isBusy && !routeStopping && !routeJumping && !routeRerouting }

    var currentPlannedSection: RouteTravelSection? {
        guard routeSectionSettingsEnabled, let route = activeRoute else { return nil }
        return RouteTravelSection.current(in: route.travelSections, at: journey?.travelledMetres ?? 0)
    }
    private func applyPlannedSection(at metres: Double) {
        guard routeSectionSettingsEnabled, let route = activeRoute,
              let section = RouteTravelSection.current(in: route.travelSections, at: metres), section.id != appliedSectionID else { return }
        appliedSectionID = section.id
        travelMode = section.mode
        motionSpeed = 0
        speedRevision += 1
    }

    func usualSpeedMPH(for mode: TravelMode) -> Double { UsualSpeedRules.value(for: mode, stored: usualSpeeds) }
    func setUsualSpeedMPH(_ value: Double, for mode: TravelMode) {
        guard value.isFinite else { return }
        usualSpeeds[mode.rawValue] = mode.clampedSpeedMPH(value)
    }
    func resetToUsualSpeed(for mode: TravelMode) { setSpeedMPH(usualSpeedMPH(for: mode), for: mode) }
    func restoreStartingUsualSpeeds() { usualSpeeds = [:] }

    func speedMPH(for mode: TravelMode) -> Double {
        if let section = currentPlannedSection, section.mode == mode {
            return mode.clampedSpeedMPH(sectionSpeedOverrides[section.id] ?? section.speedMPH)
        }
        return mode == .eBike ? EBikeSpeed.clamped(eBikeSpeedMPH) : mode.clampedSpeedMPH(modeSpeeds[mode.rawValue] ?? usualSpeedMPH(for: mode))
    }
    func setSpeedMPH(_ value: Double, for mode: TravelMode) {
        DeveloperLogStore.shared.record("speed_selected", ["mph": String(value), "mode": mode.rawValue])
        speedRevision += 1
        if let section = currentPlannedSection, section.mode == mode {
            objectWillChange.send()
            sectionSpeedOverrides[section.id] = mode.clampedSpeedMPH(value)
            if let index = activeRoute?.travelSections.firstIndex(where: { $0.id == section.id }) {
                activeRoute?.travelSections[index].speedMPH = mode.clampedSpeedMPH(value)
            }
            publishActivity(force: true)
            return
        }
        if mode == .eBike { eBikeSpeedMPH = mode.clampedSpeedMPH(value) }
        else { modeSpeeds[mode.rawValue] = mode.clampedSpeedMPH(value) }
        publishActivity(force: false)
    }
    func cruiseSpeed(for mode: TravelMode) -> Double { SpeedConversion.metresPerSecond(mph: speedMPH(for: mode)) }

    func changeTravelMode(_ mode: TravelMode, keepCurrentPath: Bool = false) {
        guard canEditRouteMovement else { return }
        guard journey == nil || !travelMode.needsRouteChoice(changingTo: mode) || keepCurrentPath else { return }
        let preserveSpeed = routeSectionSettingsEnabled && mode == travelMode ? speedMPH(for: mode) : nil
        routeSectionSettingsEnabled = false
        activeRoute?.travelSections = []
        sectionSpeedOverrides = [:]
        appliedSectionID = nil
        travelMode = mode
        if let preserveSpeed { setSpeedMPH(preserveSpeed, for: mode) }
        speedRevision += 1
        publishActivity(force: true)
    }

    @discardableResult
    func seekRoute(_ selection: RouteSeek, pairing: PairingStore) -> Bool {
        DeveloperLogStore.shared.record("route_jump_tapped", ["route": selection.routeID.uuidString, "metres": String(selection.metres)])
        guard let plan = activeRoute,
              let accepted = AcceptedRouteSeek(selection, routeID: plan.id, now: Date()) else {
            lastError = "This route marker expired. Hold the route again to choose a point."
            return false
        }
        guard canEditRouteMovement, isSpoofing, pairing.hasPairingFile else {
            lastError = isSpoofing ? "Wait for the pending route command to finish." : "Reconnect before teleporting along this route."
            return false
        }
        pendingSeek = (accepted, routePaused, nil)
        routeJumping = true
        journey?.state = .seeking
        routeActive = true
        if routeTask == nil { startRoutePlayback(plan, pairing: pairing, ticket: epoch, initialWrite: false) }
        publishActivity(force: true)
        return true
    }

    /// Keep the old path paused until a replacement is available. Stop and
    /// cancellation invalidate the request so a late result cannot restart it.
    func reroute(to mode: TravelMode, pairing: PairingStore) {
        guard let plan = activeRoute, canEditRouteMovement, isSpoofing, routeActive else { return }
        let wasPaused = routePaused
        routePaused = true
        motionSpeed = 0
        waitRevision += 1
        routeRerouting = true
        journey?.state = sendInFlight ? .pausing : .paused
        let token = UUID()
        rerouteGeneration = token
        let ticket = epoch
        publishActivity(force: true)
        rerouteTask = Task { [weak self] in
            guard let self else { return }
            do {
                while sendInFlight {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try Task.checkCancellation()
                }
                guard token == rerouteGeneration, ticket == epoch, let coordinate = simulated else { return }
                let start = RoutePlace(name: "Current simulated location", coordinate: coordinate)
                let remainingStops = plan.stops.filter { !self.stopProgress.completed.contains($0.id) }.map {
                    TripWaypoint(id: $0.id, name: $0.name, point: plan.track.point(at: $0.metres),
                        waitSeconds: $0.id == self.stopProgress.currentID ? self.stopProgress.remainingSeconds : $0.waitSeconds)
                }
                let routes = try await RouteBuilder.itinerary(from: start, to: plan.destination, via: remainingStops,
                    mode: mode, preferWalkingPaths: UserDefaults.standard.bool(forKey: "locus.preferWalkingPaths"))
                try Task.checkCancellation()
                while sendInFlight {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try Task.checkCancellation()
                }
                guard token == rerouteGeneration, ticket == epoch, activeRoute?.id == plan.id,
                      isSpoofing, let replacement = routes.first else { throw CancellationError() }
                guard pairing.hasPairingFile, replacement.source.supports(mode) else {
                    throw NSError(domain: "Locus", code: 4, userInfo: [NSLocalizedDescriptionKey: "Check pairing and choose the travel mode again."])
                }
                rerouteTask = nil
                cancelRoute()
                travelMode = mode
                if followRoute(replacement, pairing: pairing) {
                    routePaused = wasPaused
                    journey?.state = wasPaused ? .paused : .moving
                } else {
                    lastError = "The replacement could not start. Your location is held; choose a route again."
                }
            } catch {
                guard token == rerouteGeneration, ticket == epoch, activeRoute?.id == plan.id else { return }
                routeRerouting = false
                rerouteTask = nil
                routePaused = routeActive
                journey?.state = routeActive ? .paused : .arrived
                if !(error is CancellationError) { lastError = "Couldn't replace the route. Your original path is still selected. " + error.localizedDescription }
                publishActivity(force: true)
            }
        }
    }

    func cancelReroute() {
        rerouteGeneration = UUID()
        rerouteTask?.cancel()
        rerouteTask = nil
        routeRerouting = false
    }

    func toggleRoutePause() {
        DeveloperLogStore.shared.record("route_pause_continue_tapped")
        guard routeActive, canEditRouteMovement, journey?.state != .pausing else { return }
        if routePaused, effectivePhase != .active { return }
        routePaused.toggle()
        motionSpeed = 0
        waitRevision += 1
        journey?.state = RouteRefreshPolicy.stateAfterPause(paused: routePaused, writeInFlight: sendInFlight,
                                                           waitingAtStop: stopProgress.currentID != nil)
        publishActivity(force: true)
    }

    /// End playback but keep spoofing at the last location actually sent.
    /// An in-flight write cannot be cancelled; leave "Stopping route" visible
    /// until it settles, then remove the route without issuing another point.
    func stopRoute() {
        DeveloperLogStore.shared.record("stop_route_tapped")
        guard journey != nil, !routeStopping, !isBusy else { return }
        discardRecovery()
        cancelReroute()
        if let routeTask {
            routeStopping = true
            routePaused = true
            journey?.state = .stopping
            routeTask.cancel()
        } else {
            cancelRoute()
        }
        publishActivity(force: true)
    }

    private func cancelRoute(clearJourney: Bool = true) {
        cancelReroute()
        routeWorkerID = UUID()
        pendingSeek = nil
        routeJumping = false
        jumpUndo = nil
        motionSpeed = 0
        waitRevision += 1
        routeTask?.cancel()
        routeTask = nil
        routeActive = false
        routePaused = false
        routeStopping = false
        if clearJourney {
            discardRecovery()
            activeSavedTripID = nil
            activeRoute = nil; journey = nil; stopProgress = RouteStopProgress()
            routeSectionSettingsEnabled = false; sectionSpeedOverrides = [:]; appliedSectionID = nil
        }
        else { journey?.state = .interrupted }
    }

    private func beginSession() {
        locationMayRemainBeforeAttempt = requiresClear || sendInFlight
        DeveloperLogStore.shared.record("session_start_requested", ["previous_location_may_remain": String(locationMayRemainBeforeAttempt)])
        // Freeze the pre-spoof fix. Core Location may now echo our simulation.
        locationKeeper.acceptDeviceFixes = false
        epoch += 1
        if !sessionRequested { verification.reset(); sessionID = UUID(); startedAt = Date(); lastConfirmedAt = nil; sessionSpotName = nil }
        sessionRequested = true
        requiresClear = true
        UserDefaults.standard.set(true, forKey: unfinishedKey)
        warnedFailure = false
        warnedUnverified = false
        status = .connecting
        operationStartedAt = Date()
        isBusy = true
        beginBackground()
        publishActivity(force: true)
        Task {
            notificationPermission = await SessionNotifications.shared.requestPermission()
            if sessionRequested, notificationPermission, let startedAt {
                SessionNotifications.shared.scheduleReminder(minutes: preferences.reminderMinutes, startedAt: startedAt)
            }
        }
    }

    private enum CommandResult: Equatable { case sent, busy, invalidated, failed }

    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool, ticket: Int,
                       confirmedName: SessionSpotName? = nil) async -> CommandResult {
        guard ticket == epoch, sessionRequested, !stopInFlight, !Task.isCancelled else { return .invalidated }
        guard !sendInFlight else { return .busy }
        let writeID = UUID()
        activeWriteID = writeID
        sendInFlight = true
        defer {
            // An old command still owns the physical write slot until it
            // finishes, even when a queued user command has changed epochs.
            if activeWriteID == writeID {
                activeWriteID = nil
                sendInFlight = false
                if ticket == epoch { operationStartedAt = nil }
            }
        }
        operationStartedAt = Date()
        lastAttemptAt = Date()
        startMonitor(pairing: pairing)
        verification.sending()
        let commandStart = Date()
        DeveloperLogStore.shared.record("location_write_requested", ["id": writeID.uuidString,
            "latitude": String(coordinate.latitude), "longitude": String(coordinate.longitude), "epoch": String(ticket)])
        let result = await LocationEngine.set(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                              pairingPath: pairing.pairingPath, deviceIP: TunnelConfig.targetIP)
        var details = ["id": writeID.uuidString, "duration_ms": String(Int(Date().timeIntervalSince(commandStart) * 1000)),
                       "current_operation": String(ticket == epoch && sessionRequested)]
        switch result {
        case .success: details["result"] = "accepted"
        case .failure(let error): details["result"] = "failed"; details["stage"] = String(describing: error)
        }
        DeveloperLogStore.shared.record("location_write_result", details)
        guard ticket == epoch, sessionRequested else { return .invalidated }
        if isBusy { isBusy = false }
        switch result {
        case .success:
            locationMayRemainBeforeAttempt = true
            reopenedWithoutConnection = false
            let changed = status != .active
            if let confirmedName { sessionSpotName = confirmedName }
            if simulated?.latitude != coordinate.latitude || simulated?.longitude != coordinate.longitude {
                simulated = coordinate
            }
            // A keep-alive must not move the pin the user is currently choosing.
            if markRecent {
                if !pinIsPreview { pin = coordinate }
                pushRecent(coordinate)
            }
            reliability.confirmed(configuration: reliabilityConfiguration)
            let confirmedAt = Date()
            lastConfirmedAt = confirmedAt
            verification.confirmed(coordinate, at: confirmedAt)
            if changed { status = .active }
            RemoteFindMyController.shared.refreshLifecycle()
            CompanionClient.shared.tick()
            if lastError != nil { lastError = nil }
            warnedUnverified = false
            warnedFailure = false
            sessionLocationKeepAlive = true
            updateLocationTracking()
            publishActivity(force: changed)
            return .sent
        case .failure(let error):
            reliability.failed(configuration: reliabilityConfiguration)
            requiresClear = SessionFailureRules.needsClear(previousLocationMayRemain: locationMayRemainBeforeAttempt,
                                                          failedBeforeWrite: error.failedBeforeWrite)
            if !requiresClear {
                sessionRequested = false
                UserDefaults.standard.set(false, forKey: unfinishedKey)
                locationKeeper.acceptDeviceFixes = true
                pinIsPreview = pin != nil
                if pinIsPreview { previewSpotName = confirmedName }
                startedAt = nil
                SessionNotifications.shared.cancelReminder()
                monitorTask?.cancel(); monitorTask = nil
            }
            status = .dropped(error.localizedDescription)
            RemoteFindMyController.shared.refreshLifecycle()
            lastError = requiresClear ? "The update failed. The last location may still be set; Try clearing location sends a clear command. " + error.localizedDescription
                                      : "Spoofing did not start. No location was sent. " + error.localizedDescription
            // A failed final write still ends playback when Stop route was
            // explicitly requested; the session separately reports failure.
            cancelRoute(clearJourney: routeStopping)
            stopJoystick()
            sessionLocationKeepAlive = false
            updateLocationTracking()
            endBackground()
            if !warnedFailure {
                warnedFailure = true
                warn(title: requiresClear ? "Shift connection lost" : "Shift couldn’t start", message: requiresClear ? "A location update failed. The previous location may still be set." : "The connection failed before a location could be sent.")
            }
            publishActivity(force: true)
            return .failed
        }
    }

    private func tickJoystick(pairing: PairingStore, ticket: Int) async {
        guard joystickActive, isSpoofing, !sendInFlight, ticket == epoch, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let speed = cruiseSpeed(for: travelMode) * min(1.0, magnitude)
        // Resolve at each tick: rotating the map while holding the stick still
        // must keep movement aligned with the screen, not the old compass angle.
        let direction = MapJoystickProjection.vector(right: Double(joystickVector.dx),
            down: Double(joystickVector.dy), heading: joystickMapHeading)
        let coordinate = offset(coordinate: current, eastMeters: direction.east / magnitude * speed * 0.25,
                                northMeters: direction.north / magnitude * speed * 0.25)
        _ = await apply(coordinate, pairing: pairing, markRecent: false, ticket: ticket)
    }

    private weak var activePairingStore: PairingStore?

    private func startMonitor(pairing: PairingStore) {
        activePairingStore = pairing
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.monitorDelay else { return }
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard let self else { return }
                checkEvidence()
                RemoteFindMyController.shared.tick()
                CompanionClient.shared.tick()
                guard sessionRequested, !isBusy, !sendInFlight, !stopInFlight, !status.isDropped,
                      Date().timeIntervalSince(lastAttemptAt) >= connectionCheckInterval,
                      simulated != nil, shouldRefreshHeldLocation else { continue }
                let ticket = epoch
                // Keep this loop available to expire evidence while the FFI waits.
                Task {
                    // Read at dispatch time: a seek may have succeeded since
                    // the monitor woke. Never refresh an obsolete coordinate.
                    guard ticket == self.epoch, self.sessionRequested, !self.isBusy, !self.sendInFlight, !self.stopInFlight,
                          !self.status.isDropped, self.shouldRefreshHeldLocation,
                          Date().timeIntervalSince(self.lastAttemptAt) >= self.connectionCheckInterval,
                          let current = self.simulated else { return }
                    _ = await self.apply(current, pairing: pairing, markRecent: false, ticket: ticket)
                }
            }
        }
    }

    private var shouldRefreshHeldLocation: Bool {
        RouteRefreshPolicy.shouldSend(workerActive: routeTask != nil, paused: routePaused,
                                      waitingAtStop: stopProgress.currentID != nil, hasPendingSeek: pendingSeek != nil,
                                      phase: effectivePhase)
    }

    private var monitorDelay: TimeInterval {
        let refreshing = sessionRequested && !isBusy && !sendInFlight && !stopInFlight &&
            !status.isDropped && simulated != nil && shouldRefreshHeldLocation
        return SessionTiming.monitorDelay(now: Date(),
            fast: sendInFlight || stopInFlight || (routeActive && !routePaused),
            refreshAt: refreshing ? lastAttemptAt.addingTimeInterval(connectionCheckInterval) : nil,
            evidenceAt: status == .active ? lastConfirmedAt?.addingTimeInterval(connectionEvidenceLifetime) : nil,
            operationAt: operationStartedAt?.addingTimeInterval(SessionTiming.operationDeadline),
            helperAt: [RemoteFindMyController.shared.nextWakeDate, CompanionClient.shared.nextWakeDate].compactMap { $0 }.min(), interval: connectionCheckInterval)
    }

    private func checkEvidence() {
        reliability.observe(configuration: reliabilityConfiguration)
        updatePowerState()
        let timedOut = operationStartedAt.map { Date().timeIntervalSince($0) >= SessionTiming.operationDeadline } == true
        let stale = status == .active && !SessionTiming.isFresh(lastConfirmedAt, lifetime: connectionEvidenceLifetime)
        if (timedOut || stale), status != .unverified, !status.isDropped {
            status = .unverified
            if !warnedUnverified {
                warnedUnverified = true
                warn(title: "Shift status unverified", message: "No recent connection confirmation. Open Shift to check; your location may still be simulated.")
            }
            publishActivity(force: true)
        }
    }

    func becameActive(pairing: PairingStore) {
        appActive = true
        reliability.setAppActive(true, configuration: reliabilityConfiguration)
        checkEvidence()
        RemoteFindMyController.shared.refreshLifecycle()
        CompanionClient.shared.attach(self)
        CompanionClient.shared.tick()
        if sessionRequested { startMonitor(pairing: pairing); lastAttemptAt = .distantPast }
        updateLocationTracking()
        publishActivity(force: true)
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationPermission = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    func becameInactive() {
        appActive = false
        reliability.setAppActive(false, configuration: reliabilityConfiguration)
        updateLocationTracking()
    }

    func enteredBackground() {
        becameInactive()
        saveTripCheckpoint(force: true)
        reliability.observe(forceSave: true, configuration: reliabilityConfiguration)
    }

    func updatePowerState() {
        let value = ProcessInfo.processInfo.isLowPowerModeEnabled
        let changed = lowPower != value
        if changed { lowPower = value }
        if changed { reliability.observe(configuration: reliabilityConfiguration) }
        if changed { publishActivity(force: true) }
    }

    private var connectionCheckInterval: TimeInterval { TimeInterval(preferences.connectionCheckSeconds) }
    private var connectionEvidenceLifetime: TimeInterval { SessionTiming.evidenceLifetime(checkSeconds: preferences.connectionCheckSeconds) }

    func connectionCheckIntervalChanged() {
        // Wake promptly when a shorter interval is selected, without overlapping writes.
        monitorTask?.cancel(); monitorTask = nil
        if let pairing = activePairingStore, sessionRequested { startMonitor(pairing: pairing) }
        checkEvidence()
        publishActivity(force: true)
    }

    func appearanceChanged() { publishActivity(force: true, checkpoint: false) }

    func preferencesChanged() {
        publishActivity(force: true)
        if sessionRequested, let startedAt {
            SessionNotifications.shared.scheduleReminder(minutes: preferences.reminderMinutes, startedAt: startedAt)
        } else { SessionNotifications.shared.cancelReminder() }
    }

    func enableNotifications() {
        Task {
            notificationPermission = await SessionNotifications.shared.requestPermission()
            preferencesChanged()
        }
    }

    func remoteCheckDidChange() { publishActivity(force: true, checkpoint: false) }

    var reliabilityConfiguration: ReliabilityConfiguration {
        // Clearing a route as part of Stop is not a new test condition.
        if stopInFlight, let configuration = reliability.run?.configuration { return configuration }
        return ReliabilityConfiguration(appVersion: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))",
            activity: joystickActive ? .joystick : journey != nil ? .route : .heldLocation,
            findMyEnabled: RemoteFindMyController.shared.enabled || CompanionClient.shared.enabled,
            liveActivityEnabled: preferences.liveActivities, connectionCheckSeconds: preferences.connectionCheckSeconds)
    }

    private func publishActivity(force: Bool = false, checkpoint: Bool = true) {
        if checkpoint { saveTripCheckpoint(force: force) }
        guard force || Date().timeIntervalSince(lastActivityPublish) >= min(4, connectionCheckInterval) else { return }
        lastActivityPublish = Date()
        guard preferences.liveActivities, hasSession else {
            activity.sync(id: sessionID, snapshot: nil)
            return
        }
        let phase = effectivePhase
        let expiry: Date?
        switch phase {
        case .active: expiry = lastConfirmedAt?.addingTimeInterval(connectionEvidenceLifetime)
        case .connecting, .reconnecting, .stopping:
            expiry = (operationStartedAt ?? Date()).addingTimeInterval(SessionTiming.operationDeadline)
        default: expiry = nil
        }
        let place = activityPlaceLabel.map { String($0.prefix(96)) }
        let trip = journey.map { value in
            JourneyActivity(state: value.state, progress: value.fraction, remainingMetres: value.remainingMetres,
                            estimatedArrival: journeyRemainingSeconds.map { Date().addingTimeInterval($0) })
        }
        activity.sync(id: sessionID, snapshot: SessionSnapshot(phase: phase, startedAt: startedAt ?? Date(),
                      lastConfirmedAt: lastConfirmedAt, expiresAt: expiry, place: preferences.hideLocation ? nil : place,
                      lowPower: lowPower, journey: trip, islandPlace: preferences.hideIslandLocation ? nil : place,
                      lockScreenShowsProgress: preferences.lockScreenProgress, islandShowsProgress: preferences.islandProgress,
                      islandShowsTimer: preferences.islandTimer,
                      remoteFindMy: preferences.showFindMyStatus ? (RemoteFindMyController.shared.activityStatus ?? CompanionClient.shared.activityStatus) : nil, connectionCheckSeconds: preferences.connectionCheckSeconds,
                      visualStyle: preferences.visualStyle.rawValue, iconDesign: preferences.iconSelection.design.rawValue,
                      remoteLife360: preferences.showLife360Status ? (RemoteFindMyController.shared.life360ActivityStatus ?? CompanionClient.shared.life360ActivityStatus) : nil))
    }

    private func warn(title: String, message: String) {
        DeveloperLogStore.shared.record("warning_raised", ["title": title, "message": message,
            "notification_enabled": String(preferences.connectionAlerts)])
        guard preferences.connectionAlerts else { return }
        SessionNotifications.shared.warn(title: title, message: message)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.endBackground()
                DeveloperLogStore.shared.record("background_time_expired")
                // Expiry of a background task isn't evidence of disconnection.
                self.checkEvidence()
            }
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        var place = SavedPlace(
            name: trimmed.isEmpty ? "Saved place" : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        place.folder = favorites.first(where: { $0.id == place.id })?.folder
        place.icon = favorites.first(where: { $0.id == place.id })?.icon
        place.color = favorites.first(where: { $0.id == place.id })?.color
        if favorites.count >= 1000, !favorites.contains(where: { $0.id == place.id }) {
            lastError = "You have 1,000 saved places. Remove one before saving another."
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    @discardableResult
    func renameFavorite(_ place: SavedPlace, to name: String, icon: SavedPlaceSymbol? = nil, tint: SavedPlaceTint? = nil) -> Bool {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return false }
        favorites[index].name = trimmed
        if let icon { favorites[index].icon = icon.rawValue }
        if let tint { favorites[index].color = tint.rawValue }
        publishActivity(force: true)
        SavedPlace.save(favorites, key: favoritesKey)
        return true
    }

    func removeFavorite(_ place: SavedPlace) {
        guard let current = favorites.first(where: { $0.id == place.id }) else { return }
        guard RecentlyDeletedStore.shared.keep(.place(current.backupPlace)) != nil else {
            lastError = RecentlyDeletedStore.shared.error; return
        }
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func restoreFavorite(_ place: BackupPlace) -> Bool {
        guard place.isValid, favorites.count < 1000, !favorites.contains(where: { $0.id == place.id }) else {
            lastError = "Couldn't restore this place. Check your saved places and the 1,000-place limit."; return false
        }
        favorites.insert(SavedPlace(name: place.name, latitude: place.latitude, longitude: place.longitude, folder: place.folder, icon: place.icon, color: place.color), at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
        return true
    }
    func deleteNamedArea(_ area: NamedArea) {
        guard let current = namedAreas.first(where: { $0.id == area.id }) else { return }
        guard let id = RecentlyDeletedStore.shared.keep(.area(current)) else { lastError = RecentlyDeletedStore.shared.error; return }
        if !replaceNamedAreas(namedAreas.filter { $0.id != area.id }) { _ = RecentlyDeletedStore.shared.remove(id) }
    }
    func refreshRecentHistory() {
        let loaded = SavedPlace.loadRecents(retention: preferences.recentHistoryRetention, saveEnabled: preferences.saveRecentLocations)
        if loaded != recents { recents = loaded }
    }
    func clearRecentHistory() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }
    func clearFavorites() {
        guard RecentlyDeletedStore.shared.clear(kind: "Saved place") else { lastError = RecentlyDeletedStore.shared.error; return }
        favorites = []
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        recents = SavedPlace.saveRecents(recents, retention: preferences.recentHistoryRetention, saveEnabled: preferences.saveRecentLocations)
    }

    func rememberPlaceName(_ text: String, at coordinate: CLLocationCoordinate2D) {
        guard !Self.isGenericFavoriteName(text), let name = SessionSpotName(text, at: RoutePoint(coordinate)) else { return }
        chosenNames.removeAll { $0.point.distance(to: name.point) <= 5 }
        chosenNames.insert(name, at: 0)
        if chosenNames.count > 100 { chosenNames.removeLast() }
    }

    func placeName(at coordinate: CLLocationCoordinate2D) -> String? {
        let point = RoutePoint(coordinate)
        // Explicit labels outrank search titles and broader area labels.
        for label in [previewSpotName, sessionSpotName].compactMap({ $0 }) {
            if label.point.distance(to: point) <= 5 { return label.name }
        }
        if let route = activeRoute {
            let places = [route.origin, route.destination] + route.stops.map {
                RoutePlace(name: $0.name, coordinate: route.track.point(at: $0.metres).coordinate)
            }
            if let place = places.first(where: { RoutePoint($0.coordinate).distance(to: point) <= 5 && !Self.isGenericFavoriteName($0.name) }) { return place.name }
        }
        if let place = favorites.first(where: { RoutePoint($0.coordinate).distance(to: point) <= 5 && !Self.isGenericFavoriteName($0.name) }) { return place.name }
        if let name = chosenNames.first(where: { $0.point.distance(to: point) <= 5 }) { return name.name }
        if let place = recents.first(where: { RoutePoint($0.coordinate).distance(to: point) <= 5 && !Self.isGenericFavoriteName($0.name) }) { return place.name }
        return NamedArea.name(at: point, in: namedAreas)
    }

    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        placeName(at: coordinate) ?? fallback ?? "Dropped pin"
    }

    @discardableResult
    func replaceNamedAreas(_ areas: [NamedArea]) -> Bool {
        guard areas.count <= 100, areas.allSatisfy(\.isValid), Set(areas.map(\.id)).count == areas.count,
              let data = try? JSONEncoder().encode(areas) else {
            lastError = "Use a name and at least three different corners. You can save up to 100 areas."
            return false
        }
        UserDefaults.standard.set(data, forKey: "locus.namedAreas")
        namedAreas = areas
        publishActivity(force: true)
        return true
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || ["Favorite", "Saved place", "Dropped pin", "Selected place"].contains(trimmed) { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: suggestedFavoriteName(for: coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        rememberPlaceName(name, at: coordinate)
        guard preferences.saveRecentLocations else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? "Saved place" : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            visitedAt: Date()
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        recents = SavedPlace.saveRecents(recents, retention: preferences.recentHistoryRetention, saveEnabled: preferences.saveRecentLocations)
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}

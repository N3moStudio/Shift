import Combine
import CoreLocation
import Foundation

@MainActor
final class LocationVerificationController: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var report: LocationReport?
    @Published private(set) var requestedAt: Date?
    @Published private(set) var message = "Tap Check iPhone location for a fresh reading."
    private(set) var history: [SentLocationSample] = []
    private let manager = CLLocationManager()
    private var timeout: Task<Void, Never>?
    private var acceptingFixes = false
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // This check is foreground-only and separate from the actual-device fix.
        manager.allowsBackgroundLocationUpdates = false
    }
    func reset() { cancel(); history = []; report = nil; requestedAt = nil }
    func sending(at date: Date = Date()) {
        if !history.isEmpty { history[history.count - 1].validUntil = date }
    }
    func confirmed(_ coordinate: CLLocationCoordinate2D, at date: Date) {
        history.append(SentLocationSample(point: RoutePoint(coordinate), confirmedAt: date))
        history.removeAll { date.timeIntervalSince($0.confirmedAt) > 300 }
        if history.count > 2000 { history.removeFirst(history.count - 2000) }
    }
    func check() {
        cancel(); report = nil; requestedAt = Date()
        switch manager.authorizationStatus {
        case .denied, .restricted: message = "Allow Location access for Shift in iPhone Settings to run this check."; return
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        message = "Waiting for a fresh iPhone location…"
        acceptingFixes = true
        manager.startUpdatingLocation()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self else { return }
            self.acceptingFixes = false
            self.manager.stopUpdatingLocation()
            if self.report == nil { self.message = "No fresh reading arrived. Nothing confirmed; try again while Shift is open." }
        }
    }
    func cancel() {
        if acceptingFixes && report == nil { message = "Check paused. Tap Check again for a fresh reading." }
        acceptingFixes = false; timeout?.cancel(); timeout = nil; manager.stopUpdatingLocation()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard acceptingFixes, let requestedAt, let fix = locations.last, fix.timestamp >= requestedAt,
              fix.timestamp <= Date(), fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(fix.coordinate) else { return }
        report = LocationReport(provider: "iphone", target: "This iPhone", state: "ok",
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            locatedAt: fix.timestamp.timeIntervalSince1970, accuracy: fix.horizontalAccuracy,
            fetchedAt: Date().timeIntervalSince1970)
        message = "This is what iOS reported to Shift. It does not verify another app."
        if fix.horizontalAccuracy <= 100 { cancel() }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard acceptingFixes else { return }
        report = nil
        message = "The iPhone couldn't provide a fresh location. Try again while Shift is open."
        cancel()
    }
}

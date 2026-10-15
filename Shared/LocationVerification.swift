import Foundation

struct SentLocationSample: Equatable {
    let point: RoutePoint
    let confirmedAt: Date
    var validUntil: Date?
}

struct LocationReport: Codable, Equatable, Identifiable {
    var id: String { provider }
    let provider: String
    let target: String
    let state: String
    let latitude: Double?
    let longitude: Double?
    /// Provider's fix timestamp, seconds since Unix epoch, NOT request time.
    let locatedAt: Double?
    let accuracy: Double?
    let fetchedAt: Double
    var valid: Bool {
        ["iphone", "findmy-device", "findmy-person", "life360"].contains(provider) && target.count <= 120 &&
        ["ok", "old", "unavailable", "sign-in", "blocked"].contains(state) && fetchedAt.isFinite &&
        (locatedAt?.isFinite ?? true) && (accuracy.map { $0.isFinite && $0 >= 0 } ?? true) &&
        (latitude.map { $0.isFinite && (-90...90).contains($0) } ?? true) &&
        (longitude.map { $0.isFinite && (-180...180).contains($0) } ?? true)
    }
    var providerName: String {
        switch provider { case "iphone": return "This iPhone"; case "findmy-device": return "Find My · Devices"
        case "findmy-person": return "Find My · People"; default: return "Life360" }
    }
}

struct VerificationResult: Equatable {
    enum Kind { case match, different, old, unknown }
    let kind: Kind
    let text: String
    static func evaluate(_ report: LocationReport?, history: [SentLocationSample], now: Date,
                         active: Bool, requestedAfter: Date? = nil) -> Self {
        guard active else { return Self(kind: .unknown, text: "No fresh, responding session to compare.") }
        guard let report, report.valid else { return Self(kind: .unknown, text: "No location report yet.") }
        guard report.state == "ok" else {
            let text = report.state == "old" ? "The service marked this location as old." :
                report.state == "sign-in" ? "Sign in again on the computer." :
                report.state == "blocked" ? "The service declined the check. Nothing confirmed." : "Location unavailable. Nothing confirmed."
            return Self(kind: report.state == "old" ? .old : .unknown, text: text)
        }
        guard let timestamp = report.locatedAt, let lat = report.latitude, let lon = report.longitude,
              let accuracy = report.accuracy, accuracy <= 100 else {
            return Self(kind: .unknown, text: "Missing time or location, or accuracy wider than 100 m.")
        }
        let date = Date(timeIntervalSince1970: timestamp)
        let maxAge: TimeInterval = report.provider == "iphone" ? 30 : 90
        let fetchAge = now.timeIntervalSince1970 - report.fetchedAt
        guard date <= now, fetchAge >= -5, fetchAge <= 90 else {
            return Self(kind: .unknown, text: "Report clock or computer connection needs checking.")
        }
        guard now.timeIntervalSince(date) <= maxAge, requestedAfter.map({ date >= $0 }) ?? true else {
            return Self(kind: .old, text: "Waiting for a newer location. The previous one is too old.")
        }
        guard let sample = history.last(where: { $0.confirmedAt <= date }),
              date.timeIntervalSince(sample.confirmedAt) <= 40,
              sample.validUntil.map({ date < $0 }) ?? true else {
            return Self(kind: .unknown, text: "No confirmed Shift point for that report's time.")
        }
        let separation = sample.point.distance(to: RoutePoint(latitude: lat, longitude: lon))
        let tolerance = max(15, accuracy)
        if separation <= tolerance {
            return Self(kind: .match, text: "Matches the point Shift sent at that time (within \(Int(ceil(tolerance))) m).")
        }
        return Self(kind: .different, text: "Different location: about \(Int(separation.rounded())) m from Shift's point at that time.")
    }
}

struct CompanionReports: Codable {
    let version: Int
    let reports: [LocationReport]
    var valid: Bool { version == 1 && reports.count <= 3 && reports.allSatisfy(\.valid) && Set(reports.map(\.id)).count == reports.count }
}

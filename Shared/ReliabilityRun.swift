import Foundation

/// Records only evidence timing and battery samples. No location or device identifiers.
struct ReliabilityRun: Codable, Equatable, Identifiable {
    /// UIKit returns -1 when the charge is unknown. Keep that sample unknown.
    static func batteryPercent(level: Float) -> Int? {
        guard level.isFinite, (0...1).contains(level) else { return nil }
        return Int((Double(level) * 100).rounded())
    }

    var startedAt: Date
    var id: Date { startedAt }
    // Optional so results saved by earlier app versions remain readable.
    private(set) var usage: ReliabilityUsage?
    private(set) var configuration: ReliabilityConfiguration?
    private var currentCheckSeconds: Int? = nil
    private(set) var lastObservedAt: Date
    private(set) var endedAt: Date?
    private(set) var lastConfirmedAt: Date?
    private(set) var gapStartedAt: Date?
    private(set) var gapCount = 0
    private(set) var unconfirmedSeconds: TimeInterval = 0
    private(set) var failedCommands = 0
    private(set) var confirmations = 0
    var initialBattery: Int?
    private(set) var latestBattery: Int?
    private(set) var chargingObserved: Bool
    private(set) var interrupted = false
    var running: Bool { endedAt == nil }
    var duration: TimeInterval { max(0, (endedAt ?? lastObservedAt).timeIntervalSince(startedAt)) }
    var batteryDrop: Int? {
        guard !chargingObserved, let initialBattery, let latestBattery else { return nil }
        return initialBattery - latestBattery
    }

    init(now: Date, confirmedAt: Date?, battery: Int?, charging: Bool,
         appActive: Bool = true, lowPower: Bool = false, configuration: ReliabilityConfiguration? = nil) {
        startedAt = now
        lastObservedAt = now
        lastConfirmedAt = confirmedAt
        initialBattery = battery.flatMap { (0...100).contains($0) ? $0 : nil }
        latestBattery = battery
        chargingObserved = charging
        self.configuration = configuration
        usage = ReliabilityUsage(appActive: appActive, lowPower: lowPower)
        observe(now: now, battery: battery, charging: charging)
    }

    mutating func observe(now: Date, battery: Int?, charging: Bool,
                          appActive: Bool? = nil, lowPower: Bool? = nil,
                          configuration: ReliabilityConfiguration? = nil) {
        guard running, now >= lastObservedAt else { return }
        usage?.accumulate(seconds: now.timeIntervalSince(lastObservedAt), appActive: appActive, lowPower: lowPower)
        if let configuration, let original = self.configuration, configuration != original {
            usage?.configurationChanged = true
        }
        if let configuration { currentCheckSeconds = configuration.connectionCheckSeconds }
        lastObservedAt = now
        latestBattery = battery.flatMap { (0...100).contains($0) ? $0 : nil }
        chargingObserved = chargingObserved || charging
        let lifetime = (currentCheckSeconds ?? self.configuration?.connectionCheckSeconds).map { SessionTiming.evidenceLifetime(checkSeconds: $0) } ?? SessionTiming.evidenceLifetime
        if !SessionTiming.isFresh(lastConfirmedAt, now: now, lifetime: lifetime), gapStartedAt == nil {
            let expiry = lastConfirmedAt?.addingTimeInterval(lifetime) ?? startedAt
            gapStartedAt = min(now, max(startedAt, expiry))
            gapCount += 1
        }
    }

    mutating func confirm(at now: Date, battery: Int?, charging: Bool,
                         appActive: Bool? = nil, lowPower: Bool? = nil,
                         configuration: ReliabilityConfiguration? = nil) {
        guard running, now >= lastObservedAt else { return }
        // First account for a gap while suspended, before replacing its evidence.
        observe(now: now, battery: battery, charging: charging,
                appActive: appActive, lowPower: lowPower, configuration: configuration)
        closeGap(at: now)
        lastConfirmedAt = now
        confirmations += 1
    }

    mutating func failed(at now: Date, battery: Int?, charging: Bool,
                        appActive: Bool? = nil, lowPower: Bool? = nil,
                        configuration: ReliabilityConfiguration? = nil) {
        guard running, now >= lastObservedAt else { return }
        observe(now: now, battery: battery, charging: charging,
                appActive: appActive, lowPower: lowPower, configuration: configuration)
        failedCommands += 1
        if gapStartedAt == nil { gapStartedAt = now; gapCount += 1 }
    }

    mutating func finish(at now: Date, battery: Int?, charging: Bool) {
        guard running else { return }
        observe(now: max(now, lastObservedAt), battery: battery, charging: charging)
        closeGap(at: lastObservedAt)
        endedAt = lastObservedAt
    }

    mutating func endAfterRelaunch() {
        guard running else { return }
        // Do not pretend the test observed anything after its last disk sample.
        interrupted = true
        finish(at: lastObservedAt, battery: latestBattery, charging: chargingObserved)
    }

    func totalUnconfirmed(at now: Date) -> TimeInterval {
        min(duration, unconfirmedSeconds + (gapStartedAt.map { max(0, min(now, lastObservedAt).timeIntervalSince($0)) } ?? 0))
    }
    private mutating func closeGap(at now: Date) {
        if let gapStartedAt { unconfirmedSeconds += max(0, now.timeIntervalSince(gapStartedAt)) }
        gapStartedAt = nil
    }
}

struct ReliabilityUsage: Codable, Equatable {
    var appActive: Bool
    var lowPower: Bool
    private(set) var inAppSeconds: TimeInterval = 0
    private(set) var awaySeconds: TimeInterval = 0
    private(set) var lowPowerSeconds: TimeInterval = 0
    var configurationChanged = false

    mutating func accumulate(seconds: TimeInterval, appActive: Bool?, lowPower: Bool?) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if self.appActive { inAppSeconds += seconds } else { awaySeconds += seconds }
        if self.lowPower { lowPowerSeconds += seconds }
        if let appActive { self.appActive = appActive }
        if let lowPower { self.lowPower = lowPower }
    }
}

struct ReliabilityConfiguration: Codable, Equatable {
    enum Activity: String, Codable {
        case heldLocation, route, joystick
        var title: String {
            switch self {
            case .heldLocation: return "Held location"
            case .route: return "Route"
            case .joystick: return "Joystick"
            }
        }
    }
    var appVersion: String
    var activity: Activity
    var findMyEnabled: Bool
    var liveActivityEnabled: Bool
    var connectionCheckSeconds: Int? = nil
}

/// A small local archive. Finishing or restoring the same test cannot duplicate it.
struct ReliabilityHistory: Codable, Equatable {
    static let limit = 8
    private(set) var runs: [ReliabilityRun] = []

    mutating func record(_ run: ReliabilityRun) {
        guard !run.running else { return }
        runs.removeAll { $0.id == run.id }
        runs.append(run)
        runs.sort { $0.startedAt > $1.startedAt }
        runs = Array(runs.prefix(Self.limit))
    }

    mutating func remove(id: Date) { runs.removeAll { $0.id == id } }

    /// Comparisons expose context instead of declaring one run more efficient.
    static func comparisonNotes(_ current: ReliabilityRun, _ previous: ReliabilityRun) -> [String] {
        var notes: [String] = []
        if current.running || previous.running { notes.append("One test is still running.") }
        if min(current.duration, previous.duration) < 20 * 60 {
            notes.append("Use at least 20 minutes per test; short tests give coarse battery readings.")
        }
        if abs(current.duration - previous.duration) > max(60, max(current.duration, previous.duration) * 0.1) {
            notes.append("Test durations differ. Compare similar lengths.")
        }
        if current.chargingObserved || previous.chargingObserved { notes.append("Charging was detected; battery drops cannot be compared.") }
        else if current.batteryDrop == nil || previous.batteryDrop == nil { notes.append("A battery reading is missing.") }
        else if (current.batteryDrop ?? 0) < 0 || (previous.batteryDrop ?? 0) < 0 {
            notes.append("A battery reading increased. Treat the battery comparison as inconclusive.")
        }
        if current.interrupted || previous.interrupted { notes.append("A test ended when Shift closed; time after its last saved sample is excluded.") }
        if let a = current.configuration, let b = previous.configuration {
            if a.appVersion != b.appVersion { notes.append("These tests used different app builds.") }
            if a.activity != b.activity || a.findMyEnabled != b.findMyEnabled || a.liveActivityEnabled != b.liveActivityEnabled {
                notes.append("Session type or checking options differ.")
            }
        } else { notes.append("An older result has no saved setup details.") }
        if let a = current.usage, let b = previous.usage {
            if a.configurationChanged || b.configurationChanged { notes.append("Session type or checking options changed during a test.") }
            if current.duration > 0, previous.duration > 0 {
                if abs(a.inAppSeconds / current.duration - b.inAppSeconds / previous.duration) > 0.1 {
                    notes.append("Time spent inside Shift differs.")
                }
                if abs(a.lowPowerSeconds / current.duration - b.lowPowerSeconds / previous.duration) > 0.1 {
                    notes.append("Low Power Mode use differs.")
                }
            }
        } else { notes.append("An older result has no app-use timing.") }
        return notes
    }
}

import Foundation

/// Fixed recording windows, not a rolling history. Expired data is removed on
/// the next opportunity to run; iOS cannot run cleanup in a terminated app.
struct DeveloperLogWindow: Codable, Equatable {
    static let duration: TimeInterval = 48 * 60 * 60
    let startedAt: Date
    var endsAt: Date { startedAt.addingTimeInterval(Self.duration) }
    func needsReset(at now: Date) -> Bool { now >= endsAt || now < startedAt }
    func currentBatchStart(at now: Date) -> Date {
        guard now >= startedAt else { return now }
        let batches = floor(now.timeIntervalSince(startedAt) / Self.duration)
        return startedAt.addingTimeInterval(batches * Self.duration)
    }
}

struct DeveloperLogEvent: Codable {
    let time: Date
    let timeMilliseconds: Double
    let uptime: TimeInterval
    let process: String
    let event: String
    let details: [String: String]

    /// Only known high-frequency successes can wait. Unknown events, failures,
    /// user markers, and lifecycle/Stop events always flush immediately.
    var canBatch: Bool {
        switch event {
        case "location_write_requested", "live_activity_update_requested", "live_activity_update_finished": return true
        case "location_write_result": return details["result"] == "accepted"
        default: return false
        }
    }

    init(time: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
         process: String, event: String, details: [String: String] = [:]) {
        self.time = time
        self.timeMilliseconds = time.timeIntervalSince1970 * 1000
        self.uptime = uptime
        self.process = process
        self.event = String(event.prefix(100))
        // Callers supply only app-owned events, never arbitrary request bodies,
        // view text, keyboard input, pairing files, or credential dictionaries.
        self.details = Dictionary(uniqueKeysWithValues: details.keys.sorted().prefix(24).compactMap { key in
            let lower = key.lowercased()
            guard key.count <= 80, !["password", "token", "secret", "pairing", "credential", "authorization", "cookie"].contains(where: lower.contains) else { return nil }
            return (key, String((details[key] ?? "").prefix(1200)))
        })
    }
}

enum SessionFailureRules {
    /// A failure before issuing a set cannot create a new simulated location.
    /// Earlier accepted/uncertain writes must still be cleared explicitly.
    static func needsClear(previousLocationMayRemain: Bool, failedBeforeWrite: Bool) -> Bool {
        previousLocationMayRemain || !failedBeforeWrite
    }
}

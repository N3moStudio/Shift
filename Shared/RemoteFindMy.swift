import Foundation

struct RemoteFindMyLink: Codable, Equatable {
    let version: Int
    let kind: String
    let endpoint: String
    let token: String
    let certificateSHA256: String
    var usesManagedHTTPS: Bool { version == 2 && kind == "shift-findmy-render" }
    var valid: Bool {
        let hex = Set("0123456789abcdefABCDEF")
        guard endpoint.count <= 300, token.count == 64,
              token.allSatisfy({ hex.contains($0) }),
              let url = URL(string: endpoint), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        if usesManagedHTTPS {
            // A distinct format opts into system certificate validation. Legacy links
            // never fall back from their pinned certificate to ordinary HTTPS.
            guard certificateSHA256.isEmpty, url.port == nil || url.port == 443,
                  host.hasSuffix(".onrender.com") else { return false }
            let label = String(host.dropLast(".onrender.com".count))
            let letters = Set("abcdefghijklmnopqrstuvwxyz0123456789")
            guard (1...63).contains(label.count), let first = label.first, let last = label.last,
                  letters.contains(first), letters.contains(last) else { return false }
            return label.allSatisfy { letters.contains($0) || $0 == "-" }
        }
        guard version == 1, kind == "shift-findmy-cloud", certificateSHA256.count == 64,
              certificateSHA256.allSatisfy({ hex.contains($0) }),
              (1024...65535).contains(url.port ?? 0) else { return false }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let p = pieces.compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }),
              zip(pieces, p).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
        return p[0] > 0 && p[0] < 224 && ![10, 127].contains(p[0]) &&
            !(p[0] == 100 && (64...127).contains(p[1])) && !(p[0] == 169 && p[1] == 254) &&
            !(p[0] == 172 && (16...31).contains(p[1])) &&
            !(p[0] == 192 && (p[1] == 168 || p[1] == 0)) &&
            !(p[0] == 198 && (18...19).contains(p[1]))
    }
}

struct RemoteFindMySample: Codable {
    let latitude: Double
    let longitude: Double
    let confirmedAt: Double
    let validUntil: Double?
    init(_ sample: SentLocationSample) {
        latitude = sample.point.latitude; longitude = sample.point.longitude
        confirmedAt = sample.confirmedAt.timeIntervalSince1970
        validUntil = sample.validUntil?.timeIntervalSince1970
    }
}

struct RemoteFindMyRequest: Encodable {
    let version = 1
    let sessionID: UUID
    let startedAt: Double
    let sequence: Int
    let sentAt: Double
    let active: Bool
    let samples: [RemoteFindMySample]
    var providers: [String]? = nil
}

struct RemoteFindMyResponse: Decodable {
    let version: Int
    let sessionID: UUID
    let sequence: Int
    let serverTime: Double
    let status: String
    let report: LocationReport?
    var life360: CloudServiceReport? = nil
    func valid(for id: UUID, sequence expected: Int, now: Date) -> Bool {
        version == 1 && sessionID == id && sequence == expected && serverTime.isFinite &&
        abs(serverTime - now.timeIntervalSince1970) <= 30 &&
        ["match", "different", "waiting", "old", "sign-in", "blocked", "unavailable", "paused"].contains(status) &&
        (report.map { $0.valid && $0.provider == "findmy-device" } ?? true) &&
        (life360?.valid(provider: "life360") ?? true)
    }
}

enum RemoteFindMyState: String, Codable, Hashable {
    case off, ready, waiting, match, different, old, signIn, blocked, unavailable, paused, pairing
    var title: String {
        switch self {
        case .off: return "Find My checks off"
        case .ready: return "Ready for your next session"
        case .waiting: return "Waiting for a Find My report"
        case .match: return "Find My matches"
        case .different: return "Find My shows somewhere else"
        case .old: return "Apple's location report is old"
        case .signIn: return "Apple sign-in needed"
        case .blocked: return "Apple declined the check"
        case .unavailable: return "Find My check unavailable"
        case .paused: return "Find My checks paused"
        case .pairing: return "Reconnect the cloud helper"
        }
    }
    var warning: String? {
        switch self {
        case .different: return "A recent Find My Devices report differs from the point Shift sent at that time. Open Shift to review."
        case .signIn: return "Sign in to Apple again in your helper. Find My checks are unavailable until you reconnect."
        case .blocked: return "Apple declined the request. Open your helper to review access; checks have paused."
        case .unavailable: return "Shift couldn't get a report from the helper or Apple. This doesn't mean spoofing stopped."
        case .pairing: return "The helper didn't accept its access key or session. Open Remote Find My to reconnect."
        case .old: return "Waiting for Apple to refresh its location. An old report does not mean Find My shows a different place."
        case .waiting: return "Waiting for a Find My location that can be compared with this session."
        default: return nil
        }
    }
    static func evaluate(_ response: RemoteFindMyResponse?, history: [SentLocationSample], now: Date, active: Bool,
                         life360: Bool = false) -> Self {
        guard active else { return .paused }
        guard let response, abs(response.serverTime - now.timeIntervalSince1970) <= 90 else { return .unavailable }
        guard !life360 || response.life360 != nil else { return .unavailable }
        let status = life360 ? response.life360!.status : response.status
        switch status {
        case "sign-in": return .signIn
        case "blocked": return .blocked
        case "unavailable": return .unavailable
        case "paused": return .paused
        default: break
        }
        guard let report = life360 ? response.life360?.report : response.report else { return .waiting }
        switch VerificationResult.evaluate(report, history: history, now: now, active: active).kind {
        case .match: return status == "match" ? .match : .waiting
        case .different: return status == "different" ? .different : .waiting
        case .old: return .old
        case .unknown: return .waiting
        }
    }
}

/// Evidence shown separately from the developer connection in Live Activities.
/// Always describe a match as a past observation, never a continuous guarantee.
struct RemoteFindMyActivity: Codable, Hashable {
    var state: RemoteFindMyState
    var reportedAt: Date?
    var repliedAt: Date?

    func presented(at now: Date, systemIsStale: Bool = false) -> RemoteFindMyState {
        switch state {
        case .off, .ready, .paused, .signIn, .blocked, .pairing, .unavailable: return state
        default: break
        }
        guard !systemIsStale, let repliedAt,
              (0...90).contains(now.timeIntervalSince(repliedAt)) else { return .unavailable }
        if let reportedAt, !(0...90).contains(now.timeIntervalSince(reportedAt)) { return .old }
        if state == .match || state == .different {
            guard reportedAt != nil else { return .waiting }
        }
        return state
    }

    func title(at now: Date, systemIsStale: Bool = false, life360: Bool = false) -> String {
        if life360 {
            switch presented(at: now, systemIsStale: systemIsStale) {
            case .match: return "Last Life360 report matched"
            case .different: return "Last Life360 report differed"
            default: return presented(at: now, systemIsStale: systemIsStale).life360Title
            }
        }
        switch presented(at: now, systemIsStale: systemIsStale) {
        case .match: return "Last Find My report matched"
        case .different: return "Last Find My report differed"
        case .old: return "Find My: Apple report is old"
        case .unavailable: return "Find My: no recent check"
        default: return presented(at: now, systemIsStale: systemIsStale).title
        }
    }
}

/// Slow repeated failures without changing evidence freshness or the normal
/// one-minute cadence. Even a 20-second timeout plus the maximum retry delay
/// fits inside the helper's 150-second lease while the app is running.
struct RemoteFindMyRetryPolicy {
    private(set) var failures = 0
    mutating func reset() { failures = 0 }
    mutating func failureDelay() -> TimeInterval {
        failures = min(failures + 1, 3)
        return [60.0, 90.0, 120.0][failures - 1]
    }
}

struct RemoteFindMyAlertGate {
    private(set) var lastState: RemoteFindMyState?
    private(set) var lastAlertAt: Date?
    mutating func shouldNotify(_ state: RemoteFindMyState, now: Date, lastFresh: Date) -> Bool {
        if state == .match { lastState = nil; return false }
        guard state.warning != nil, state != lastState,
              lastAlertAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return false }
        if (state == .old || state == .waiting) && now.timeIntervalSince(lastFresh) < 180 { return false }
        lastState = state; lastAlertAt = now
        return true
    }
}

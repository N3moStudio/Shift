import Foundation

enum RecentHistoryRetention: String, CaseIterable, Identifiable, Codable {
    case forever, oneDay, oneWeek, oneMonth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .forever: return "Keep until I delete"
        case .oneDay: return "After 24 hours"
        case .oneWeek: return "After 7 days"
        case .oneMonth: return "After 30 days"
        }
    }
    var lifetime: TimeInterval? {
        switch self {
        case .forever: return nil
        case .oneDay: return 86_400
        case .oneWeek: return 7 * 86_400
        case .oneMonth: return 30 * 86_400
        }
    }
    func keeps(visitedAt: Date?, now: Date) -> Bool {
        guard let lifetime else { return true }
        // Undated legacy history cannot establish that it is inside the limit.
        guard let visitedAt, visitedAt.timeIntervalSince1970.isFinite else { return false }
        let age = now.timeIntervalSince(visitedAt)
        return age >= 0 && age < lifetime
    }
}

/// Authentication results must belong to the current foreground attempt.
struct PrivacyAccessState {
    enum Activity { case active, inactive, background }
    private(set) var authenticationEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var activity: Activity = .inactive
    private(set) var attemptID: UUID?

    init(authenticationEnabled: Bool) {
        self.authenticationEnabled = authenticationEnabled
        isLocked = authenticationEnabled
    }
    var canOpenContent: Bool { activity == .active && !isLocked }
    func needsCover(hideInSwitcher: Bool) -> Bool {
        isLocked || (activity != .active && (hideInSwitcher || authenticationEnabled))
    }
    mutating func setAuthenticationEnabled(_ enabled: Bool, authenticated: Bool = false) {
        let changed = authenticationEnabled != enabled
        authenticationEnabled = enabled
        if !enabled { isLocked = false }
        else if changed { isLocked = !authenticated }
    }
    mutating func becameActive() { activity = .active }
    mutating func becameInactive() { activity = .inactive }
    mutating func enteredBackground() {
        activity = .background
        if authenticationEnabled { isLocked = true }
        attemptID = nil
    }
    mutating func beginAuthentication() -> UUID? {
        guard activity == .active, attemptID == nil else { return nil }
        let id = UUID()
        attemptID = id
        return id
    }
    @discardableResult
    mutating func finishAuthentication(_ id: UUID, success: Bool) -> Bool {
        guard attemptID == id, activity != .background else { return false }
        attemptID = nil
        if success { isLocked = false }
        return true
    }
}

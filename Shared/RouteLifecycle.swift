import Foundation

/// A route worker sleeps until the state it depends on changes. Revisions
/// prevent a change just before registration from being lost; cancellation
/// removes only that waiter's continuation, never a replacement worker's.
@MainActor
final class RouteWakeSignal {
    private(set) var revision: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var waitingCount: Int { waiters.count }

    func signal() {
        revision &+= 1
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func wait(after observed: UInt64) async {
        guard observed == revision, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard observed == revision, !Task.isCancelled else { continuation.resume(); return }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
        }
    }
}

enum UsualSpeedRules {
    static let preferenceKey = "locus.usualSpeeds"
    static func initialMPH(for mode: TravelMode) -> Double {
        switch mode {
        case .walk: return 3
        case .run: return 6
        case .cycle: return 12
        case .eBike: return 15
        case .drive: return 25
        }
    }
    static func value(for mode: TravelMode, stored: [String: Double]) -> Double {
        guard let value = stored[mode.rawValue], value.isFinite else { return initialMPH(for: mode) }
        return mode.clampedSpeedMPH(value)
    }
}

enum LiveRouteStopInsertion {
    enum Failure: Error, Equatable {
        case invalid, limit, alreadyPassed
        var message: String {
            switch self {
            case .invalid: return "Choose a valid point and wait time on this route."
            case .limit: return "This route already has 20 stops."
            case .alreadyPassed: return "You have reached that spot while editing. Choose a point farther ahead."
            }
        }
    }
    static func make(name: String, metres: Double, waitSeconds: Double, length: Double,
                     travelled: Double, pendingMetres: Double?, existingCount: Int) -> Result<RouteStop, Failure> {
        guard length.isFinite, length > 0, travelled.isFinite, travelled >= 0,
              metres.isFinite, metres <= length, StopDuration.isValid(waitSeconds),
              pendingMetres.map({ $0.isFinite && $0 >= 0 }) ?? true else { return .failure(.invalid) }
        guard existingCount < 20 else { return .failure(.limit) }
        // A command already in flight may land beyond the last confirmed point.
        // Never insert a stop behind either position or silently rewind playback.
        guard metres > max(travelled, pendingMetres ?? travelled) + 0.5 else { return .failure(.alreadyPassed) }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        return .success(RouteStop(name: trimmed.isEmpty ? "Stop \(existingCount + 1)" : trimmed,
                                  metres: metres, waitSeconds: waitSeconds))
    }
}

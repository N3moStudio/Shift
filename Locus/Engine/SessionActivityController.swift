import ActivityKit
import Combine
import Foundation

@MainActor
final class SessionActivityController: ObservableObject {
    @Published private(set) var issue: String?
    private struct Request {
        var id: UUID
        var snapshot: SessionSnapshot?
    }
    private var pending: Request?
    private var draining = false

    var isAuthorized: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// One serial writer prevents a delayed 'active' update overtaking a stop or
    /// failure. Frequent movement updates are coalesced to the latest snapshot.
    func sync(id: UUID, snapshot: SessionSnapshot?) {
        pending = Request(id: id, snapshot: snapshot)
        guard !draining else { return }
        draining = true
        Task {
            while let request = pending {
                pending = nil
                await apply(request)
            }
            draining = false
        }
    }

    private func apply(_ request: Request) async {
        let existing = Activity<LocusActivityAttributes>.activities
        for activity in existing where request.snapshot == nil || activity.attributes.sessionID != request.id {
            var endingState = activity.content.state
            endingState.phase = .idle
            endingState.place = nil
            endingState.islandPlace = nil
            endingState.expiresAt = nil
            endingState.journey = nil
            await activity.end(ActivityContent(state: endingState, staleDate: nil), dismissalPolicy: .immediate)
        }
        guard var snapshot = request.snapshot else { issue = nil; return }
        // A queued payload may already have expired while an older write ended.
        snapshot.phase = snapshot.presentedPhase(at: Date())
        if snapshot.phase != .active { snapshot.journey = nil }
        guard isAuthorized else {
            issue = "Live Activities are disabled in iPhone Settings for Shift."
            DeveloperLogStore.shared.record("live_activity_unavailable", ["reason": "not_authorized"])
            return
        }
        let content = ActivityContent(state: snapshot, staleDate: snapshot.expiresAt)
        if let activity = Activity<LocusActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == request.id && ($0.activityState == .active || $0.activityState == .stale)
        }) {
            // Compare the full evidence payload, including confirmation times
            // and expiry. Fresh acknowledgements must still extend staleDate.
            guard activity.content.state != snapshot || activity.content.staleDate != snapshot.expiresAt else {
                issue = nil
                return
            }
            await activity.update(content)
            DeveloperLogStore.shared.record("live_activity_update_finished", ["meaning": "API returned; not proof of onscreen rendering"])
            issue = nil
        } else {
            do {
                _ = try Activity.request(attributes: LocusActivityAttributes(sessionID: request.id),
                                         content: content, pushType: nil)
                DeveloperLogStore.shared.record("live_activity_created")
                issue = nil
            } catch {
                DeveloperLogStore.shared.record("live_activity_request_failed", ["domain": (error as NSError).domain, "code": String((error as NSError).code)])
                issue = "Live Activity unavailable. Open Shift and retry; make sure its app extension was kept during installation."
            }
        }
    }
}

import XCTest
@testable import SessionPresentation

final class PlaybackLifecycleTests: XCTestCase {
    func testMovingRouteOwnsFreshLocationWrites() {
        XCTAssertFalse(RouteRefreshPolicy.shouldSend(workerActive: true, paused: false,
            waitingAtStop: false, hasPendingSeek: false, phase: .active))
        XCTAssertTrue(RouteRefreshPolicy.shouldSend(workerActive: false, paused: false,
            waitingAtStop: false, hasPendingSeek: false, phase: .active))
    }

    func testPauseAndStopWaitKeepConnectionRefreshes() {
        XCTAssertTrue(RouteRefreshPolicy.shouldSend(workerActive: true, paused: true,
            waitingAtStop: false, hasPendingSeek: false, phase: .active))
        XCTAssertTrue(RouteRefreshPolicy.shouldSend(workerActive: true, paused: false,
            waitingAtStop: true, hasPendingSeek: false, phase: .active))
    }

    func testAcceptedJumpTakesPriorityOverHeldPositionRefresh() {
        for paused in [false, true] {
            XCTAssertFalse(RouteRefreshPolicy.shouldSend(workerActive: true, paused: paused,
                waitingAtStop: true, hasPendingSeek: true, phase: .active))
        }
    }

    func testStaleRouteCanRefreshBeforeResumingOrExecutingJump() {
        for paused in [false, true] {
            XCTAssertTrue(RouteRefreshPolicy.shouldSend(workerActive: true, paused: paused,
                waitingAtStop: false, hasPendingSeek: true, phase: .unverified))
        }
        for phase in [SessionPhase.idle, .stopping, .disconnected] {
            XCTAssertFalse(RouteRefreshPolicy.shouldSend(workerActive: true, paused: true,
                waitingAtStop: true, hasPendingSeek: true, phase: phase))
        }
    }

    func testTapAcceptsPreviewBeforeExpiryAndDoesNotExpireWhileQueued() throws {
        let id = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let preview = RouteSeek(routeID: id, metres: 300, expiresAt: now.addingTimeInterval(30))
        let command = try XCTUnwrap(AcceptedRouteSeek(preview, routeID: id, now: now.addingTimeInterval(29)))
        XCTAssertFalse(preview.isValid(routeID: id, now: now.addingTimeInterval(60)))
        XCTAssertTrue(command.belongs(to: id))
        XCTAssertEqual(command.metres, 300)
        XCTAssertFalse(command.belongs(to: nil))
        XCTAssertFalse(command.belongs(to: UUID()))
    }

    func testExpiredOrReplacedPreviewCannotBecomeCommand() {
        let id = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let preview = RouteSeek(routeID: id, metres: 300, expiresAt: now)
        XCTAssertNil(AcceptedRouteSeek(preview, routeID: id, now: now))
        XCTAssertNil(AcceptedRouteSeek(preview, routeID: UUID(), now: now.addingTimeInterval(-1)))
        XCTAssertNil(AcceptedRouteSeek(RouteSeek(routeID: id, metres: .nan, expiresAt: now.addingTimeInterval(1)),
                                     routeID: id, now: now))
    }

    func testPausingDuringWriteRetainsProgressAndContinueReturnsToSamePath() {
        var progress = JourneyProgress(totalMetres: 1000)
        progress.confirmPosition(300)
        progress.state = RouteRefreshPolicy.stateAfterPause(paused: true, writeInFlight: true, waitingAtStop: false)
        XCTAssertEqual(progress.state, .pausing)
        progress.confirmPosition(302) // The one already-issued command finishes.
        progress.state = RouteRefreshPolicy.stateAfterPause(paused: true, writeInFlight: false, waitingAtStop: false)
        XCTAssertEqual(progress.state, .paused)
        XCTAssertEqual(progress.travelledMetres, 302)
        progress.state = RouteRefreshPolicy.stateAfterPause(paused: false, writeInFlight: false, waitingAtStop: false)
        XCTAssertEqual(progress.state, .moving)
        XCTAssertEqual(progress.travelledMetres, 302)
    }

    func testContinueAtStopPreservesRemainingWait() {
        let stop = RouteStop(name: "Wait here", metres: 100, waitSeconds: 60)
        var stops = RouteStopProgress()
        stops.arrive(stop)
        stops.tick(0.5)
        XCTAssertEqual(RouteRefreshPolicy.stateAfterPause(paused: true, writeInFlight: false,
            waitingAtStop: stops.currentID != nil), .paused)
        XCTAssertEqual(RouteRefreshPolicy.stateAfterPause(paused: false, writeInFlight: false,
            waitingAtStop: stops.currentID != nil), .waiting)
        XCTAssertEqual(stops.remainingSeconds, 59.5)
        XCTAssertEqual(stops.currentID, stop.id)
    }
}

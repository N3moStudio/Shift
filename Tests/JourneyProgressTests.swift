import XCTest
@testable import SessionPresentation

final class JourneyProgressTests: XCTestCase {
    func testProgressOnlyChangesWhenMovementIsConfirmed() {
        var progress = JourneyProgress(totalMetres: 1000)
        XCTAssertEqual(progress.remainingMetres, 1000)
        progress.confirmMovement(100)
        XCTAssertEqual(progress.travelledMetres, 100)
        XCTAssertEqual(progress.remainingMetres, 900)
        XCTAssertEqual(progress.fraction, 0.1, accuracy: 0.000001)
    }

    func testProgressCannotReverseOverflowOrBecomeNonFinite() {
        var progress = JourneyProgress(totalMetres: 100)
        progress.confirmMovement(-5)
        progress.confirmMovement(.nan)
        progress.confirmMovement(.infinity)
        XCTAssertEqual(progress.travelledMetres, 0)
        progress.confirmMovement(500)
        XCTAssertEqual(progress.travelledMetres, 100)
        XCTAssertEqual(progress.remainingMetres, 0)
        XCTAssertEqual(progress.fraction, 1)
    }

    func testETAChangesWithSpeedAndConfirmedDistance() throws {
        var progress = JourneyProgress(totalMetres: 1000)
        XCTAssertEqual(try XCTUnwrap(progress.remainingSeconds(speed: 10, fresh: true)), 100)
        progress.confirmMovement(250)
        XCTAssertEqual(try XCTUnwrap(progress.remainingSeconds(speed: 5, fresh: true)), 150)
        XCTAssertNil(progress.remainingSeconds(speed: 0, fresh: true))
    }

    func testNoETAWhilePausedPausingStoppingInterruptedArrivedOrStale() {
        var progress = JourneyProgress(totalMetres: 100)
        XCTAssertNil(progress.remainingSeconds(speed: 1, fresh: false))
        for state in [JourneyState.pausing, .paused, .stopping, .seeking, .interrupted, .arrived] {
            progress.state = state
            XCTAssertNil(progress.remainingSeconds(speed: 1, fresh: true))
        }
        progress.state = .moving
        XCTAssertNotNil(progress.remainingSeconds(speed: 1, fresh: true))
    }

    func testJoystickCannotStartSpoofingFromAnIdleOrRestoredSession() {
        for phase in [SessionPhase.idle, .active, .unverified] {
            XCTAssertEqual(JoystickAccess.check(sessionRequested: false, hasLocation: true,
                                               phase: phase, hasRoute: false, isBusy: false), .notStarted)
        }
        XCTAssertEqual(JoystickAccess.check(sessionRequested: true, hasLocation: false,
                                           phase: .active, hasRoute: false, isBusy: false), .notStarted)
    }

    func testJoystickRequiresFreshConnectionEvidence() {
        for phase in [SessionPhase.idle, .connecting, .reconnecting, .unverified, .disconnected, .stopping] {
            XCTAssertEqual(JoystickAccess.check(sessionRequested: true, hasLocation: true,
                                               phase: phase, hasRoute: false, isBusy: false), .needsConnection)
        }
    }

    func testJoystickDoesNotReplaceARouteOrInterruptAnOperation() {
        XCTAssertEqual(JoystickAccess.check(sessionRequested: true, hasLocation: true,
                                           phase: .active, hasRoute: true, isBusy: false), .routeInProgress)
        XCTAssertEqual(JoystickAccess.check(sessionRequested: true, hasLocation: true,
                                           phase: .active, hasRoute: false, isBusy: true), .busy)
        XCTAssertEqual(JoystickAccess.check(sessionRequested: true, hasLocation: true,
                                           phase: .active, hasRoute: false, isBusy: false), .ready)
    }

    func testStepSelectionFollowsConfirmedProgress() {
        let steps = [RouteInstruction(id: 0, text: "First", endDistance: 100),
                     RouteInstruction(id: 1, text: "Second", endDistance: 300)]
        var progress = JourneyProgress(totalMetres: 300)
        XCTAssertEqual(progress.instructionIndex(in: steps), 0)
        progress.confirmMovement(100)
        XCTAssertEqual(progress.instructionIndex(in: steps), 1)
        progress.confirmMovement(200)
        XCTAssertEqual(progress.instructionIndex(in: steps), 1)
        XCTAssertNil(progress.instructionIndex(in: []))
    }

    func testLiveJourneyDisappearsWhenEvidenceExpires() {
        let now = Date(timeIntervalSince1970: 1800000000)
        let trip = JourneyActivity(state: .moving, progress: 0.5, remainingMetres: 100,
                                   estimatedArrival: now.addingTimeInterval(60))
        let snapshot = SessionSnapshot(phase: .active, startedAt: now, lastConfirmedAt: now,
            expiresAt: now.addingTimeInterval(12), place: nil, lowPower: true, journey: trip)
        XCTAssertNotNil(snapshot.presentedJourney(at: now))
        XCTAssertNil(snapshot.presentedJourney(at: now.addingTimeInterval(12)))
        XCTAssertNil(snapshot.presentedJourney(at: now, systemIsStale: true))
    }

    func testActivityJourneyHasNoDestinationCoordinatesOrStreetNames() throws {
        let trip = JourneyActivity(state: .paused, progress: 0.5, remainingMetres: 100, estimatedArrival: nil)
        let data = try JSONEncoder().encode(trip)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["destination"])
        XCTAssertNil(object["coordinates"])
        XCTAssertNil(object["instruction"])
        XCTAssertNil(object["estimatedArrival"])
        XCTAssertEqual(try JSONDecoder().decode(JourneyActivity.self, from: data), trip)
        XCTAssertLessThan(data.count, 500)
    }
}

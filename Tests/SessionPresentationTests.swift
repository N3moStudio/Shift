import XCTest
@testable import SessionPresentation

final class SessionPresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(_ phase: SessionPhase, expiry: Date?) -> SessionSnapshot {
        SessionSnapshot(phase: phase, startedAt: now.addingTimeInterval(-100), lastConfirmedAt: now,
                        expiresAt: expiry, place: nil, lowPower: true)
    }

    func testSuspendedAppCannotLeaveActiveStatusPastDeadline() {
        let state = snapshot(.active, expiry: now.addingTimeInterval(12))
        XCTAssertEqual(state.presentedPhase(at: now.addingTimeInterval(11)), .active)
        XCTAssertEqual(state.presentedPhase(at: now.addingTimeInterval(12)), .unverified)
        XCTAssertEqual(state.presentedPhase(at: now.addingTimeInterval(3600)), .unverified)
    }

    func testSystemStalenessOverridesFreshTimestamp() {
        let state = snapshot(.active, expiry: now.addingTimeInterval(12))
        XCTAssertEqual(state.presentedPhase(at: now, systemIsStale: true), .unverified)
    }

    func testLostStopResponseNeverClaimsStopped() {
        let state = snapshot(.stopping, expiry: now.addingTimeInterval(12))
        XCTAssertEqual(state.presentedPhase(at: now), .stopping)
        XCTAssertEqual(state.presentedPhase(at: now.addingTimeInterval(13)), .unverified)
    }

    func testKnownFailureIsNotReplacedByUnknownWhenStale() {
        XCTAssertEqual(snapshot(.disconnected, expiry: now).presentedPhase(at: now, systemIsStale: true), .disconnected)
        XCTAssertEqual(snapshot(.idle, expiry: now).presentedPhase(at: now, systemIsStale: true), .idle)
    }

    func testInitialConnectionAndReconnectHaveDeadlines() {
        for phase in [SessionPhase.connecting, .reconnecting] {
            XCTAssertEqual(snapshot(phase, expiry: now).presentedPhase(at: now), .unverified)
        }
    }

    func testNoEvidenceOrClockRollbackIsNotFresh() {
        XCTAssertFalse(SessionTiming.isFresh(nil, now: now))
        XCTAssertFalse(SessionTiming.isFresh(now.addingTimeInterval(1), now: now))
        XCTAssertFalse(SessionTiming.isFresh(now.addingTimeInterval(-12), now: now))
        XCTAssertTrue(SessionTiming.isFresh(now.addingTimeInterval(-5), now: now))
    }

    func testHeldLocationMonitorKeepsFiveSecondRefreshWithoutOneSecondPolling() {
        XCTAssertEqual(SessionTiming.monitorDelay(now: now, fast: false,
            refreshAt: now.addingTimeInterval(5), evidenceAt: now.addingTimeInterval(12),
            operationAt: nil, helperAt: now.addingTimeInterval(60)), 5)
        XCTAssertEqual(SessionTiming.monitorDelay(now: now, fast: true,
            refreshAt: nil, evidenceAt: now.addingTimeInterval(12), operationAt: nil, helperAt: nil), 1)
    }

    func testMonitorWakesForEachEarlierDeadlineAndDoesNotSpinOnExpiredEvidence() {
        let early = now.addingTimeInterval(0.25)
        for index in 0..<4 {
            var dates: [Date?] = Array(repeating: nil, count: 4)
            dates[index] = early
            XCTAssertEqual(SessionTiming.monitorDelay(now: now, fast: false,
                refreshAt: dates[0], evidenceAt: dates[1], operationAt: dates[2], helperAt: dates[3]), 0.25)
        }
        XCTAssertEqual(SessionTiming.monitorDelay(now: now, fast: false, refreshAt: now,
            evidenceAt: nil, operationAt: nil, helperAt: nil), 0.01)
        XCTAssertEqual(SessionTiming.monitorDelay(now: now, fast: false, refreshAt: nil,
            evidenceAt: now.addingTimeInterval(-1), operationAt: now.addingTimeInterval(-1), helperAt: nil), 5)
    }

    func testPrivacyPayloadHasNoCoordinatesAndRoundTrips() throws {
        let state = snapshot(.active, expiry: now.addingTimeInterval(12))
        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["place"])
        XCTAssertNil(object["latitude"])
        XCTAssertNil(object["longitude"])
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: data), state)
        XCTAssertLessThan(data.count, 4096)
    }
}

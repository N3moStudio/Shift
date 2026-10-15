import XCTest
@testable import SessionPresentation

final class ConnectionCadenceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBoundsAndDefault() {
        XCTAssertEqual(SessionTiming.defaultCheckSeconds, 10)
        XCTAssertEqual(SessionTiming.checkSeconds(-1), 3)
        XCTAssertEqual(SessionTiming.checkSeconds(99), 15)
    }

    func testHeldLocationUsesSelectedCadenceButEarlierDeadlinesStillWin() {
        for seconds in [3, 10, 15] {
            XCTAssertEqual(SessionTiming.monitorDelay(now: now, fast: false,
                refreshAt: now.addingTimeInterval(Double(seconds)), evidenceAt: nil,
                operationAt: nil, helperAt: nil, interval: Double(seconds)), Double(seconds))
            XCTAssertEqual(SessionTiming.monitorDelay(now: now, fast: false,
                refreshAt: now.addingTimeInterval(Double(seconds)), evidenceAt: nil,
                operationAt: now.addingTimeInterval(0.5), helperAt: nil, interval: Double(seconds)), 0.5)
        }
    }

    func testLiveActivityExpiresWithoutAppUpdatesForEveryCadence() throws {
        for seconds in [3, 10, 15] {
            let lifetime = SessionTiming.evidenceLifetime(checkSeconds: seconds)
            let state = SessionSnapshot(phase: .active, startedAt: now, lastConfirmedAt: now,
                expiresAt: now.addingTimeInterval(lifetime), place: nil, lowPower: false,
                connectionCheckSeconds: seconds)
            XCTAssertEqual(state.presentedPhase(at: now.addingTimeInterval(lifetime - 0.01)), .active)
            XCTAssertEqual(state.presentedPhase(at: now.addingTimeInterval(lifetime)), .unverified)
            XCTAssertEqual(state.presentedPhase(at: now, systemIsStale: true), .unverified)
            XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(state)), state)
        }
    }

    func testOlderActivitiesStillExpireAtTheirOriginalDeadline() throws {
        let state = SessionSnapshot(phase: .active, startedAt: now, lastConfirmedAt: now,
            expiresAt: now.addingTimeInterval(12), place: nil, lowPower: false)
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("connectionCheckSeconds"))
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.presentedPhase(at: now.addingTimeInterval(12)), .unverified)
    }

    func testComputerFailuresHaveDistinctRecoveryPaths() {
        XCTAssertNil(CompanionConnectionIssue.http(200))
        XCTAssertEqual(CompanionConnectionIssue.http(401), .pairing)
        XCTAssertEqual(CompanionConnectionIssue.http(503), .server)
        for (code, expected) in [(-1001, CompanionConnectionIssue.timeout), (-1022, .localAccess), (-1202, .certificate), (-1004, .network)] {
            XCTAssertEqual(CompanionConnectionIssue.transport(NSError(domain: NSURLErrorDomain, code: code)), expected)
        }
    }
    func testReliabilityEvidenceUsesCadenceAndRecordsChanges() {
        var config = ReliabilityConfiguration(appVersion: "test", activity: .heldLocation,
            findMyEnabled: false, liveActivityEnabled: true, connectionCheckSeconds: 15)
        var run = ReliabilityRun(now: now, confirmedAt: now, battery: 80, charging: false, configuration: config)
        run.observe(now: now.addingTimeInterval(16), battery: 80, charging: false, configuration: config)
        XCTAssertEqual(run.gapCount, 0)
        config.connectionCheckSeconds = 3
        run.observe(now: now.addingTimeInterval(17), battery: 80, charging: false, configuration: config)
        XCTAssertTrue(run.usage?.configurationChanged == true)
        XCTAssertEqual(run.gapCount, 1)
    }
}

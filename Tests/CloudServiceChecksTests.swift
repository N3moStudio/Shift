import XCTest
@testable import SessionPresentation

final class CloudServiceChecksTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func report(provider: String = "life360", age: Double = 2) -> LocationReport {
        LocationReport(provider: provider, target: "Me", state: "ok", latitude: 37, longitude: -122,
                       locatedAt: now.timeIntervalSince1970 - age, accuracy: 5, fetchedAt: now.timeIntervalSince1970)
    }
    var history: [SentLocationSample] {
        [SentLocationSample(point: RoutePoint(latitude: 37, longitude: -122), confirmedAt: now.addingTimeInterval(-10))]
    }
    func response(_ life: CloudServiceReport? = nil) -> RemoteFindMyResponse {
        RemoteFindMyResponse(version: 1, sessionID: UUID(), sequence: 1, serverTime: now.timeIntervalSince1970,
                            status: "sign-in", report: nil, life360: life)
    }
    func testLifeMatchIndependentOfAppleLoginButRequiresLocalEvidence() {
        let value = response(CloudServiceReport(status: "match", report: report()))
        XCTAssertTrue(value.valid(for: value.sessionID, sequence: 1, now: now))
        XCTAssertEqual(RemoteFindMyState.evaluate(value, history: history, now: now, active: true), .signIn)
        XCTAssertEqual(RemoteFindMyState.evaluate(value, history: history, now: now, active: true, life360: true), .match)
        XCTAssertEqual(RemoteFindMyState.evaluate(value, history: [], now: now, active: true, life360: true), .waiting)
        XCTAssertEqual(RemoteFindMyState.evaluate(value, history: history, now: now, active: false, life360: true), .paused)
    }
    func testLegacyResponseHasNoLifeEvidenceAndCannotBecomeMatch() throws {
        let value = response()
        let json = """
        {"version":1,"sessionID":"\(value.sessionID)","sequence":1,"serverTime":\(now.timeIntervalSince1970),"status":"sign-in"}
        """
        let old = try JSONDecoder().decode(RemoteFindMyResponse.self, from: Data(json.utf8))
        XCTAssertNil(old.life360)
        XCTAssertTrue(old.valid(for: value.sessionID, sequence: 1, now: now))
        XCTAssertEqual(RemoteFindMyState.evaluate(old, history: history, now: now, active: true, life360: true), .unavailable)
    }
    func testWrongProviderAndInventedStatusAreRejected() {
        for life in [CloudServiceReport(status: "match", report: report(provider: "findmy-device")),
                     CloudServiceReport(status: "guaranteed", report: report())] {
            let value = response(life)
            XCTAssertFalse(value.valid(for: value.sessionID, sequence: 1, now: now))
        }
    }
    func testLifeOldAndBlockedNeverBorrowAppleFreshness() {
        let old = response(CloudServiceReport(status: "match", report: report(age: 100)))
        XCTAssertEqual(RemoteFindMyState.evaluate(old, history: history, now: now, active: true, life360: true), .old)
        let blocked = response(CloudServiceReport(status: "blocked", report: report()))
        XCTAssertEqual(RemoteFindMyState.evaluate(blocked, history: history, now: now, active: true, life360: true), .blocked)
        let disagreement = response(CloudServiceReport(status: "different", report: report()))
        XCTAssertEqual(RemoteFindMyState.evaluate(disagreement, history: history, now: now, active: true, life360: true), .waiting)
    }
    func testBothServicesUseOneSnapshotAndExpireIndependently() throws {
        let apple = RemoteFindMyActivity(state: .match, reportedAt: now, repliedAt: now)
        let life = RemoteFindMyActivity(state: .match, reportedAt: now.addingTimeInterval(-89), repliedAt: now)
        let snapshot = SessionSnapshot(phase: .active, startedAt: now, lowPower: false, remoteFindMy: apple, remoteLife360: life)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertLessThan(encoded.count + 100, 4096)
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: encoded), snapshot)
        XCTAssertEqual(apple.presented(at: now.addingTimeInterval(2)), .match)
        XCTAssertEqual(life.presented(at: now.addingTimeInterval(2)), .old)
        XCTAssertEqual(life.presented(at: now, systemIsStale: true), .unavailable)
        XCTAssertEqual(life.title(at: now, life360: true), "Last Life360 report matched")
        var hidden = snapshot
        hidden.remoteLife360 = nil
        XCTAssertNotNil(hidden.remoteFindMy)
        hidden.remoteFindMy = nil
        XCTAssertNil(hidden.remoteFindMy)
    }
    func testTransportMessagesDistinguishKeySessionWakeAndOffline() {
        XCTAssertEqual(CloudConnectionIssue.http(401), .key)
        XCTAssertEqual(CloudConnectionIssue.http(409), .session)
        XCTAssertEqual(CloudConnectionIssue.http(503), .waking)
        XCTAssertEqual(CloudConnectionIssue.http(429), .limited)
        XCTAssertEqual(CloudConnectionIssue.transport(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(CloudConnectionIssue.transport(URLError(.timedOut)), .waking)
        XCTAssertEqual(CloudConnectionIssue.transport(URLError(.serverCertificateUntrusted)), .certificate)
        XCTAssertNil(CloudConnectionIssue.http(200))
    }
}

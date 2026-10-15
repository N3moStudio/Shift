import XCTest
@testable import SessionPresentation

final class RemoteFindMyTests: XCTestCase {
    func testFailureBackoffIsBoundedAndSuccessRestoresFirstRetry() {
        var retry = RemoteFindMyRetryPolicy()
        XCTAssertEqual(retry.failureDelay(), 60)
        XCTAssertEqual(retry.failureDelay(), 90)
        XCTAssertEqual(retry.failureDelay(), 120)
        for _ in 0..<100 {
            // Request timeout + monitor jitter must still fit the lease.
            XCTAssertLessThan(retry.failureDelay() + 20 + 5, 150)
        }
        retry.reset()
        XCTAssertEqual(retry.failureDelay(), 60)
    }

    func testRetryBackoffNeverExtendsMatchEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let evidence = RemoteFindMyActivity(state: .match, reportedAt: now, repliedAt: now)
        var retry = RemoteFindMyRetryPolicy()
        _ = retry.failureDelay()
        _ = retry.failureDelay()
        let delayedRetry = now.addingTimeInterval(retry.failureDelay())
        XCTAssertEqual(evidence.presented(at: delayedRetry), .unavailable)
        XCTAssertEqual(evidence.presented(at: now.addingTimeInterval(89)), .match)
    }

    let id = UUID()
    let now = Date(timeIntervalSince1970: 1000)
    var history: [SentLocationSample] { [SentLocationSample(point: RoutePoint(latitude: 37, longitude: -122), confirmedAt: Date(timeIntervalSince1970: 980))] }
    func response(status: String = "match", time: Double = 995, id: UUID? = nil, sequence: Int = 1, server: Double = 1000) -> RemoteFindMyResponse {
        RemoteFindMyResponse(version: 1, sessionID: id ?? self.id, sequence: sequence, serverTime: server, status: status,
            report: LocationReport(provider: "findmy-device", target: "Test", state: "ok", latitude: 37, longitude: -122,
                locatedAt: time, accuracy: 5, fetchedAt: 1000))
    }
    func testRejectsOtherSessionSequenceAndClock() {
        XCTAssertTrue(response().valid(for: id, sequence: 1, now: now))
        XCTAssertFalse(response(id: UUID()).valid(for: id, sequence: 1, now: now))
        XCTAssertFalse(response(sequence: 2).valid(for: id, sequence: 1, now: now))
        XCTAssertFalse(response(server: 900).valid(for: id, sequence: 1, now: now))
        XCTAssertFalse(response(status: "guaranteed-safe").valid(for: id, sequence: 1, now: now))
    }
    func testCloudCannotOverrideMissingLocalEvidence() {
        XCTAssertEqual(RemoteFindMyState.evaluate(response(), history: [], now: now, active: true), .waiting)
        XCTAssertEqual(RemoteFindMyState.evaluate(response(), history: history, now: now, active: false), .paused)
    }
    func testGreenExpiresWithoutAnotherNetworkRequest() {
        XCTAssertEqual(RemoteFindMyState.evaluate(response(), history: history, now: now, active: true), .match)
        XCTAssertEqual(RemoteFindMyState.evaluate(response(), history: history, now: now.addingTimeInterval(91), active: true), .unavailable)
    }
    func testOldAppleTimestampCannotBeMadeFresh() {
        XCTAssertEqual(RemoteFindMyState.evaluate(response(time: 800), history: history, now: now, active: true), .old)
    }
    func testLiveActivityExpiresMatchOnOldAppleReportDespiteRecentHelperReply() {
        let snapshot = RemoteFindMyActivity(state: .match, reportedAt: now.addingTimeInterval(-89), repliedAt: now)
        XCTAssertEqual(snapshot.presented(at: now), .match)
        XCTAssertEqual(snapshot.presented(at: now.addingTimeInterval(2)), .old)
        XCTAssertEqual(snapshot.title(at: now), "Last Find My report matched")
    }
    func testLiveActivityCannotShowMatchWhenUpdatesStopOrEvidenceIsMissing() {
        let snapshot = RemoteFindMyActivity(state: .match, reportedAt: now, repliedAt: now)
        XCTAssertEqual(snapshot.presented(at: now.addingTimeInterval(91)), .unavailable)
        XCTAssertEqual(snapshot.presented(at: now, systemIsStale: true), .unavailable)
        XCTAssertEqual(RemoteFindMyActivity(state: .match, reportedAt: nil, repliedAt: now).presented(at: now), .waiting)
        XCTAssertEqual(RemoteFindMyActivity(state: .match, reportedAt: now, repliedAt: nil).presented(at: now), .unavailable)
        XCTAssertEqual(RemoteFindMyActivity(state: .signIn, reportedAt: now, repliedAt: now).presented(at: now), .signIn)
    }
    func testNewActivityEvidenceRoundTripsAndOldActivitiesStillDecode() throws {
        let remote = RemoteFindMyActivity(state: .old, reportedAt: now.addingTimeInterval(-180), repliedAt: now)
        let snapshot = SessionSnapshot(phase: .active, startedAt: now, lowPower: false, remoteFindMy: remote)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: data).remoteFindMy, remote)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "remoteFindMy")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(SessionSnapshot.self, from: legacyData).remoteFindMy)
    }
    func testSignInAndBlockedNeverShowGreen() {
        XCTAssertEqual(RemoteFindMyState.evaluate(response(status: "sign-in"), history: history, now: now, active: true), .signIn)
        XCTAssertEqual(RemoteFindMyState.evaluate(response(status: "blocked"), history: history, now: now, active: true), .blocked)
    }
    func testCloudAndPhoneMustAgree() {
        XCTAssertEqual(RemoteFindMyState.evaluate(response(status: "different"), history: history, now: now, active: true), .waiting)
    }
    func testNotificationsDeduplicateAndAllowRecoveredFailure() {
        var gate = RemoteFindMyAlertGate()
        XCTAssertTrue(gate.shouldNotify(.signIn, now: now, lastFresh: now))
        XCTAssertFalse(gate.shouldNotify(.signIn, now: now.addingTimeInterval(100), lastFresh: now))
        XCTAssertFalse(gate.shouldNotify(.match, now: now.addingTimeInterval(110), lastFresh: now))
        XCTAssertTrue(gate.shouldNotify(.signIn, now: now.addingTimeInterval(120), lastFresh: now))
    }
    func testWaitingGraceAndNotificationCooldown() {
        var gate = RemoteFindMyAlertGate()
        XCTAssertFalse(gate.shouldNotify(.waiting, now: now.addingTimeInterval(179), lastFresh: now))
        XCTAssertTrue(gate.shouldNotify(.waiting, now: now.addingTimeInterval(180), lastFresh: now))
        XCTAssertFalse(gate.shouldNotify(.signIn, now: now.addingTimeInterval(181), lastFresh: now))
        XCTAssertFalse(gate.shouldNotify(.paused, now: now.addingTimeInterval(300), lastFresh: now))
    }
    func testCloudLinkRequiresPublicHTTPSExactKindAndFullKeys() {
        let hex = String(repeating: "a", count: 64)
        func link(_ endpoint: String, kind: String = "shift-findmy-cloud") -> RemoteFindMyLink {
            RemoteFindMyLink(version: 1, kind: kind, endpoint: endpoint, token: hex, certificateSHA256: hex)
        }
        XCTAssertTrue(link("https://8.8.8.8:8765").valid)
        for endpoint in ["http://8.8.8.8:8765", "https://192.168.1.1:8765", "https://127.0.0.1:8765", "https://100.64.0.1:8765",
                         "https://8.8.8.8:8765/redirect", "https://8.8.8.8:8765?key=x", "https://user@8.8.8.8:8765", "https://8.8.8.8"] {
            XCTAssertFalse(link(endpoint).valid, endpoint)
        }
        XCTAssertFalse(link("https://8.8.8.8:8765", kind: "local").valid)
    }

    func testRenderLinkUsesSeparateFormatAndOnlyExactPublicRenderHosts() {
        let hex = String(repeating: "a", count: 64)
        func link(_ endpoint: String, version: Int = 2, kind: String = "shift-findmy-render",
                  certificate: String = "") -> RemoteFindMyLink {
            RemoteFindMyLink(version: version, kind: kind, endpoint: endpoint, token: hex, certificateSHA256: certificate)
        }
        XCTAssertTrue(link("https://example-helper.onrender.com").valid)
        XCTAssertTrue(link("https://example-helper.onrender.com:443/").valid)
        XCTAssertTrue(link("https://example-helper.onrender.com").usesManagedHTTPS)
        for endpoint in ["http://example-helper.onrender.com", "https://onrender.com", "https://evil.onrender.com.example.com",
                         "https://a.b.onrender.com", "https://-bad.onrender.com", "https://bad-.onrender.com",
                         "https://127.0.0.1", "https://8.8.8.8:8765", "https://localhost", "https://example-helper.onrender.com:8765",
                         "https://user@example-helper.onrender.com", "https://example-helper.onrender.com?key=secret",
                         "https://example-helper.onrender.com/path", "https://example-helper.onrender.com#secret"] {
            XCTAssertFalse(link(endpoint).valid, endpoint)
        }
        XCTAssertFalse(link("https://example-helper.onrender.com", certificate: hex).valid)
        XCTAssertFalse(link("https://example-helper.onrender.com", version: 1).valid)
        XCTAssertFalse(link("https://example-helper.onrender.com", version: 3).valid)
        XCTAssertFalse(link("https://8.8.8.8:8765", version: 1, kind: "shift-findmy-cloud").valid)
        XCTAssertTrue(link("https://8.8.8.8:8765", version: 1, kind: "shift-findmy-cloud", certificate: hex).valid)
    }
}

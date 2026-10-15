import XCTest
@testable import SessionPresentation

final class LocationVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private let point = RoutePoint(latitude: 37, longitude: -122)
    private var history: [SentLocationSample] { [SentLocationSample(point: point, confirmedAt: Date(timeIntervalSince1970: 980))] }
    private func report(time: Double? = 995, fetched: Double = 1000, accuracy: Double? = 5,
                        state: String = "ok", latitude: Double = 37, provider: String = "life360") -> LocationReport {
        LocationReport(provider: provider, target: "Test", state: state, latitude: latitude,
                       longitude: -122, locatedAt: time, accuracy: accuracy, fetchedAt: fetched)
    }
    private func result(_ report: LocationReport, active: Bool = true) -> VerificationResult {
        VerificationResult.evaluate(report, history: history, now: now, active: active)
    }
    func testFreshAccurateReportMatches() { XCTAssertEqual(result(report()).kind, .match) }
    func testFreshDifferentReportDoesNotMatch() { XCTAssertEqual(result(report(latitude: 38)).kind, .different) }
    func testNewDownloadDoesNotMakeOldLocationFresh() { XCTAssertEqual(result(report(time: 800)).kind, .old) }
    func testProviderOldFlagWins() { XCTAssertEqual(result(report(state: "old")).kind, .old) }
    func testBlockedAndSignedOutNeverMatch() {
        XCTAssertEqual(result(report(state: "blocked")).kind, .unknown)
        XCTAssertEqual(result(report(state: "sign-in")).kind, .unknown)
    }
    func testMissingAccuracyOrTimestampNeverMatches() {
        XCTAssertEqual(result(report(time: nil)).kind, .unknown)
        XCTAssertEqual(result(report(accuracy: nil)).kind, .unknown)
        XCTAssertEqual(result(report(accuracy: 101)).kind, .unknown)
    }
    func testBadNumbersAndFutureTimesNeverMatch() {
        XCTAssertFalse(report(accuracy: .nan).valid)
        XCTAssertFalse(report(latitude: 100).valid)
        XCTAssertEqual(result(report(time: 1001)).kind, .unknown)
        XCTAssertEqual(result(report(fetched: 1010)).kind, .unknown)
    }
    func testExpiredComputerConnectionDoesNotMatch() { XCTAssertEqual(result(report(fetched: 800)).kind, .unknown) }
    func testNoActiveSessionDoesNotMatchEvenWithMatchingCoordinates() { XCTAssertEqual(result(report(), active: false).kind, .unknown) }
    func testPreSessionAndOldCommandEvidenceCannotMatch() {
        XCTAssertEqual(result(report(time: 975)).kind, .unknown)
        let ancient = [SentLocationSample(point: point, confirmedAt: Date(timeIntervalSince1970: 900))]
        XCTAssertEqual(VerificationResult.evaluate(report(), history: ancient, now: now, active: true).kind, .unknown)
    }
    func testInFlightGapDoesNotGetComparedToPreviousCommand() {
        var samples = history
        samples[0].validUntil = Date(timeIntervalSince1970: 994)
        samples.append(SentLocationSample(point: point, confirmedAt: Date(timeIntervalSince1970: 996)))
        XCTAssertEqual(VerificationResult.evaluate(report(), history: samples, now: now, active: true).kind, .unknown)
    }
    func testMovementUsesHistoricalPointNotNewestPoint() {
        var samples = history
        samples[0].validUntil = Date(timeIntervalSince1970: 996)
        samples.append(SentLocationSample(point: RoutePoint(latitude: 38, longitude: -122), confirmedAt: Date(timeIntervalSince1970: 997)))
        XCTAssertEqual(VerificationResult.evaluate(report(), history: samples, now: now, active: true).kind, .match)
    }
    func testLocalCheckRejectsReadingFromBeforeButtonTap() {
        XCTAssertEqual(VerificationResult.evaluate(report(provider: "iphone"), history: history, now: now,
            active: true, requestedAfter: Date(timeIntervalSince1970: 996)).kind, .old)
    }
    func testDuplicateAndUnexpectedProviderReportsRejected() {
        XCTAssertFalse(CompanionReports(version: 1, reports: [report(), report()]).valid)
        XCTAssertFalse(report(provider: "made-up").valid)
    }
    func testCompanionPairRequiresPrivateHTTPSAndFullKeys() {
        let key = String(repeating: "a", count: 64)
        XCTAssertTrue(CompanionLink(version: 1, endpoint: "https://192.168.1.5:8765", token: key, certificateSHA256: key).valid)
        for endpoint in ["http://192.168.1.5:8765", "https://evil.example", "https://8.8.8.8", "https://user@192.168.1.5", "https://192.168.1.5/redirect", "https://192.168.1.5?token=x"] {
            XCTAssertFalse(CompanionLink(version: 1, endpoint: endpoint, token: key, certificateSHA256: key).valid)
        }
        XCTAssertFalse(CompanionLink(version: 1, endpoint: "https://192.168.1.5", token: "short", certificateSHA256: key).valid)
    }
}

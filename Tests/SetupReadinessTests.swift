import XCTest
@testable import SessionPresentation

final class SetupReadinessTests: XCTestCase {
    func testVPNAndPairingNeverReplaceInitialWiFiRequirement() {
        XCTAssertEqual(SetupReadiness.prerequisite(wifiAvailable: false, tunnelDetected: true,
            hasPairing: true, hasSession: false), .wifiRequired)
        XCTAssertEqual(SetupReadiness.prerequisite(wifiAvailable: nil, tunnelDetected: true,
            hasPairing: true, hasSession: false), .checkingWiFi)
    }

    func testPrerequisitesIdentifyTheFirstMissingStep() {
        XCTAssertEqual(SetupReadiness.prerequisite(wifiAvailable: true, tunnelDetected: false,
            hasPairing: false, hasSession: false), .pairingRequired)
        XCTAssertEqual(SetupReadiness.prerequisite(wifiAvailable: true, tunnelDetected: true,
            hasPairing: false, hasSession: false), .pairingRequired)
        XCTAssertNil(SetupReadiness.prerequisite(wifiAvailable: true, tunnelDetected: true,
            hasPairing: true, hasSession: false))
    }

    func testMissingInterfaceHintDoesNotBlockDeveloperCheck() {
        XCTAssertNil(SetupReadiness.prerequisite(wifiAvailable: true, tunnelDetected: false, hasPairing: true, hasSession: false))
    }

    func testExistingOrUnfinishedSessionBlocksSetupProbe() {
        XCTAssertEqual(SetupReadiness.prerequisite(wifiAvailable: true, tunnelDetected: true,
            hasPairing: true, hasSession: true), .activeSession)
        XCTAssertEqual(SetupReadiness.prerequisite(wifiAvailable: nil, tunnelDetected: false,
            hasPairing: false, hasSession: true), .activeSession)
    }

    func testOnlyTheCurrentCheckCanFinish() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var check = SetupCheckLifecycle()
        let previous = check.begin()
        let current = check.begin()
        check.finish(previous, issue: nil, now: now)
        XCTAssertEqual(check.state, .checking)
        check.finish(current, issue: .pairingRejected, now: now)
        XCTAssertEqual(check.state, .failed(.pairingRejected))
    }

    func testCancelledAndTimedOutChecksIgnoreLateSuccess() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for issue in [SetupIssue.cancelled, .timedOut, .wifiRequired, .vpnRequired] {
            var check = SetupCheckLifecycle()
            let id = check.begin()
            check.invalidate(issue)
            check.finish(id, issue: nil, now: now)
            XCTAssertEqual(check.state, .failed(issue))
            XCTAssertFalse(check.isVerified(now: now, prerequisite: nil))
        }
    }

    func testSuccessExpiresAndNeedsPrerequisitesToRemainPresent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var check = SetupCheckLifecycle()
        let id = check.begin()
        check.finish(id, issue: nil, now: now)
        XCTAssertTrue(check.isVerified(now: now.addingTimeInterval(59), prerequisite: nil))
        XCTAssertFalse(check.isVerified(now: now.addingTimeInterval(60), prerequisite: nil))
        XCTAssertFalse(check.isVerified(now: now.addingTimeInterval(-1), prerequisite: nil))
        for issue in [SetupIssue.wifiRequired, .vpnRequired, .pairingRequired, .activeSession] {
            XCTAssertFalse(check.isVerified(now: now, prerequisite: issue))
        }
    }

    func testFailureHelpReturnsToTheRelevantSetupStep() {
        XCTAssertEqual(SetupIssue.wifiRequired.step, .wifi)
        XCTAssertEqual(SetupIssue.tunnelUnavailable.step, .vpn)
        XCTAssertEqual(SetupIssue.invalidAddress.step, .vpn)
        XCTAssertEqual(SetupIssue.pairingRejected.step, .pairing)
        XCTAssertEqual(SetupIssue.serviceUnavailable.step, .connection)
        XCTAssertEqual(SetupIssue.timedOut.step, .connection)
    }

    func testSuccessBelongsToTheExactPairingRevisionAndTunnelAddress() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revision = UUID()
        let checked = SetupConfiguration(pairingRevision: revision, tunnelAddress: "10.7.0.1")
        var check = SetupCheckLifecycle()
        let id = check.begin(configuration: checked)
        check.finish(id, issue: nil, now: now)
        XCTAssertTrue(check.isVerified(now: now, prerequisite: nil, configuration: checked))
        XCTAssertFalse(check.isVerified(now: now, prerequisite: nil,
            configuration: SetupConfiguration(pairingRevision: UUID(), tunnelAddress: checked.tunnelAddress)))
        XCTAssertFalse(check.isVerified(now: now, prerequisite: nil,
            configuration: SetupConfiguration(pairingRevision: revision, tunnelAddress: "10.7.0.2")))
        check.invalidate(.configurationChanged)
        check.finish(id, issue: nil, now: now)
        XCTAssertEqual(check.state, .failed(.configurationChanged))
    }
}

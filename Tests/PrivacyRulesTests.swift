import XCTest
@testable import SessionPresentation

final class PrivacyRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRetentionExpiresAtLimitAndKeepsNewerHistory() {
        XCTAssertTrue(RecentHistoryRetention.oneDay.keeps(visitedAt: now.addingTimeInterval(-86_399), now: now))
        XCTAssertFalse(RecentHistoryRetention.oneDay.keeps(visitedAt: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(RecentHistoryRetention.oneWeek.keeps(visitedAt: now.addingTimeInterval(-2 * 86_400), now: now))
        XCTAssertFalse(RecentHistoryRetention.oneMonth.keeps(visitedAt: now.addingTimeInterval(-31 * 86_400), now: now))
    }
    func testFiniteRetentionRejectsUndatedAndFutureHistory() {
        XCTAssertFalse(RecentHistoryRetention.oneDay.keeps(visitedAt: nil, now: now))
        XCTAssertFalse(RecentHistoryRetention.oneDay.keeps(visitedAt: now.addingTimeInterval(10), now: now))
        XCTAssertTrue(RecentHistoryRetention.forever.keeps(visitedAt: nil, now: now))
    }
    func testProtectedColdLaunchStartsLockedAndCannotOpenDocuments() {
        var state = PrivacyAccessState(authenticationEnabled: true)
        XCTAssertTrue(state.isLocked)
        XCTAssertTrue(state.needsCover(hideInSwitcher: false))
        state.becameActive()
        XCTAssertFalse(state.canOpenContent)
    }
    func testCancellationLeavesProtectedAppLocked() throws {
        var state = PrivacyAccessState(authenticationEnabled: true)
        state.becameActive()
        let attempt = try XCTUnwrap(state.beginAuthentication())
        XCTAssertTrue(state.finishAuthentication(attempt, success: false))
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.canOpenContent)
        XCTAssertNil(state.attemptID)
    }
    func testAuthenticationInactiveTransitionDoesNotInvalidateAttempt() throws {
        var state = PrivacyAccessState(authenticationEnabled: true)
        state.becameActive()
        let attempt = try XCTUnwrap(state.beginAuthentication())
        state.becameInactive()
        XCTAssertEqual(state.attemptID, attempt)
        XCTAssertTrue(state.finishAuthentication(attempt, success: true))
        XCTAssertFalse(state.isLocked)
        XCTAssertFalse(state.canOpenContent)
        XCTAssertTrue(state.needsCover(hideInSwitcher: false))
        state.becameActive()
        XCTAssertTrue(state.canOpenContent)
        XCTAssertFalse(state.needsCover(hideInSwitcher: true))
    }
    func testBackgroundInvalidatesAuthenticationAndRejectsLateSuccess() throws {
        var state = PrivacyAccessState(authenticationEnabled: true)
        state.becameActive()
        let attempt = try XCTUnwrap(state.beginAuthentication())
        state.enteredBackground()
        state.becameActive()
        XCTAssertFalse(state.finishAuthentication(attempt, success: true))
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.canOpenContent)
    }
    func testOldCompletionCannotFinishANewerAttempt() throws {
        var state = PrivacyAccessState(authenticationEnabled: true)
        state.becameActive()
        let old = try XCTUnwrap(state.beginAuthentication())
        state.enteredBackground()
        state.becameActive()
        let current = try XCTUnwrap(state.beginAuthentication())
        XCTAssertFalse(state.finishAuthentication(old, success: true))
        XCTAssertEqual(state.attemptID, current)
        XCTAssertTrue(state.isLocked)
    }
    func testAuthCannotStartInBackgroundOrOverlap() throws {
        var state = PrivacyAccessState(authenticationEnabled: true)
        XCTAssertNil(state.beginAuthentication())
        state.becameActive()
        _ = try XCTUnwrap(state.beginAuthentication())
        XCTAssertNil(state.beginAuthentication())
        state.enteredBackground()
        XCTAssertNil(state.beginAuthentication())
    }
    func testSuccessfulUnlockRelocksOnlyAfterBackground() throws {
        var state = PrivacyAccessState(authenticationEnabled: true)
        state.becameActive()
        let attempt = try XCTUnwrap(state.beginAuthentication())
        state.finishAuthentication(attempt, success: true)
        state.becameInactive()
        state.becameActive()
        XCTAssertFalse(state.isLocked)
        state.enteredBackground()
        state.becameActive()
        XCTAssertTrue(state.isLocked)
    }
    func testCoverWithoutAppLockDoesNotRequireAuthenticationOnReturn() {
        var state = PrivacyAccessState(authenticationEnabled: false)
        XCTAssertTrue(state.needsCover(hideInSwitcher: true))
        XCTAssertFalse(state.needsCover(hideInSwitcher: false))
        state.enteredBackground()
        state.becameActive()
        XCTAssertTrue(state.canOpenContent)
        XCTAssertFalse(state.isLocked)
    }
    func testEnablingAfterSuccessfulConfirmationDoesNotRelockImmediately() {
        var state = PrivacyAccessState(authenticationEnabled: false)
        state.becameActive()
        state.setAuthenticationEnabled(true, authenticated: true)
        XCTAssertTrue(state.canOpenContent)
        state.setAuthenticationEnabled(true)
        XCTAssertTrue(state.canOpenContent)
        state.enteredBackground()
        XCTAssertTrue(state.isLocked)
    }
}

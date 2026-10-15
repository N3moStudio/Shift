import XCTest
@testable import SessionPresentation

final class RouteLifecycleTests: XCTestCase {
    private func make(metres: Double = 500, wait: Double = 60, travelled: Double = 100,
                      pending: Double? = nil, count: Int = 0) -> Result<RouteStop, LiveRouteStopInsertion.Failure> {
        LiveRouteStopInsertion.make(name: "  Coffee  ", metres: metres, waitSeconds: wait,
            length: 1000, travelled: travelled, pendingMetres: pending, existingCount: count)
    }
    func testLiveStopMustStayAheadOfConfirmedAndInFlightPositions() throws {
        let valid = try make(metres: 301, pending: 300).get()
        XCTAssertEqual(valid.metres, 301)
        XCTAssertEqual(valid.name, "Coffee")
        XCTAssertEqual(failure(make(metres: 100)), .alreadyPassed)
        XCTAssertEqual(failure(make(metres: 200, pending: 300)), .alreadyPassed)
        XCTAssertEqual(failure(make(metres: 300.5, pending: 300)), .alreadyPassed)
    }
    func testLiveStopRejectsPointPassedDuringEditingInsteadOfRewinding() throws {
        XCTAssertNoThrow(try make(metres: 500, travelled: 100).get())
        XCTAssertEqual(failure(make(metres: 500, travelled: 501)), .alreadyPassed)
        XCTAssertEqual(failure(make(metres: 500, travelled: 490, pending: 510)), .alreadyPassed)
    }
    func testLiveStopValidatesLimitGeometryAndWaitWithoutClampingSilently() {
        XCTAssertEqual(failure(make(count: 20)), .limit)
        XCTAssertEqual(failure(make(metres: .nan)), .invalid)
        XCTAssertEqual(failure(make(metres: 1001)), .invalid)
        XCTAssertEqual(failure(make(wait: -1)), .invalid)
        XCTAssertEqual(failure(make(wait: 3601)), .invalid)
        XCTAssertEqual(failure(make(pending: .infinity)), .invalid)
    }
    func testAddingFutureStopPreservesCurrentWaitAndCompletedStops() throws {
        let first = RouteStop(name: "First", metres: 10, waitSeconds: 0)
        let current = RouteStop(name: "Current", metres: 100, waitSeconds: 60)
        let last = RouteStop(name: "Last", metres: 900, waitSeconds: 30)
        var progress = RouteStopProgress()
        progress.arrive(first)
        progress.arrive(current)
        progress.tick(0.5)
        let before = progress
        let inserted = try make(metres: 500, travelled: 100).get()
        let stops = [first, current, inserted, last]
        XCTAssertEqual(progress, before)
        XCTAssertEqual(progress.currentID, current.id)
        XCTAssertEqual(progress.remainingSeconds, 59.5)
        XCTAssertEqual(progress.remainingWait(in: stops), 149.5)
        progress.finish()
        XCTAssertEqual(progress.next(in: stops)?.id, inserted.id)
        XCTAssertTrue(progress.completed.contains(first.id))
        XCTAssertTrue(progress.completed.contains(current.id))
    }
    func testLiveStopCanWaitAtDestinationAndPassThroughWithZeroWait() throws {
        let destination = try make(metres: 1000, wait: 0).get()
        var progress = RouteStopProgress()
        progress.arrive(destination)
        XCTAssertNil(progress.currentID)
        XCTAssertTrue(progress.completed.contains(destination.id))
    }
    func testJumpUndoWindowIsExactlyTenSeconds() {
        let id = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let undo = RouteJumpUndo(routeID: id, metres: 100, wasPaused: false,
            stops: RouteStopProgress(), expiresAt: now.addingTimeInterval(RouteJumpUndo.duration))
        XCTAssertEqual(RouteJumpUndo.duration, 10)
        XCTAssertTrue(undo.isValid(routeID: id, now: now.addingTimeInterval(9.99)))
        XCTAssertFalse(undo.isValid(routeID: id, now: now.addingTimeInterval(10)))
    }
    func testUsualSpeedDefaultsMatchRequestedModes() {
        XCTAssertEqual(UsualSpeedRules.value(for: .walk, stored: [:]), 3)
        XCTAssertEqual(UsualSpeedRules.value(for: .run, stored: [:]), 6)
        XCTAssertEqual(UsualSpeedRules.value(for: .cycle, stored: [:]), 12)
        XCTAssertEqual(UsualSpeedRules.value(for: .eBike, stored: [:]), 15)
        XCTAssertEqual(UsualSpeedRules.value(for: .drive, stored: [:]), 25)
    }
    func testUsualSpeedNormalizesBadPreferencesAndLeavesValidChoicesIntact() {
        XCTAssertEqual(UsualSpeedRules.value(for: .walk, stored: ["walk": 100]), 6)
        XCTAssertEqual(UsualSpeedRules.value(for: .eBike, stored: ["eBike": -1]), 1)
        XCTAssertEqual(UsualSpeedRules.value(for: .drive, stored: ["drive": .nan]), 25)
        XCTAssertEqual(UsualSpeedRules.value(for: .run, stored: ["run": 8.4]), 8.4)
        XCTAssertEqual(UsualSpeedRules.value(for: .eBike, stored: ["eBike": 35]), 35)
    }
    private func failure(_ result: Result<RouteStop, LiveRouteStopInsertion.Failure>) -> LiveRouteStopInsertion.Failure? {
        if case .failure(let value) = result { return value }
        return nil
    }
}

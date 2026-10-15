import XCTest
@testable import SessionPresentation

final class RouteWakeSignalTests: XCTestCase {
    @MainActor
    private func registered(_ count: Int, on signal: RouteWakeSignal) async {
        for _ in 0..<100 {
            if signal.waitingCount == count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(signal.waitingCount, count)
    }

    @MainActor
    func testChangeBeforeWaitIsNotLost() async {
        let signal = RouteWakeSignal(), done = expectation(description: "Already changed")
        let observed = signal.revision
        signal.signal()
        let task = Task { await signal.wait(after: observed); done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        task.cancel()
        XCTAssertEqual(signal.waitingCount, 0)
    }

    @MainActor
    func testSignalResumesAllWaitersAndCancellationDoesNotCancelReplacement() async {
        let signal = RouteWakeSignal()
        let cancelled = expectation(description: "Cancelled worker exits")
        let first = Task { await signal.wait(after: signal.revision); cancelled.fulfill() }
        await registered(1, on: signal)
        let resumed = expectation(description: "Replacement and second waiter resume")
        resumed.expectedFulfillmentCount = 2
        let second = Task { await signal.wait(after: signal.revision); resumed.fulfill() }
        let third = Task { await signal.wait(after: signal.revision); resumed.fulfill() }
        await registered(3, on: signal)
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(signal.waitingCount, 2)
        signal.signal()
        await fulfillment(of: [resumed], timeout: 1)
        second.cancel(); third.cancel()
        XCTAssertEqual(signal.waitingCount, 0)
    }

    @MainActor
    func testConnectionHeartbeatDoesNotWakePausedControls() async {
        let controls = RouteWakeSignal(), connection = RouteWakeSignal()
        let resumed = expectation(description: "Resume control")
        let task = Task { await controls.wait(after: controls.revision); resumed.fulfill() }
        await registered(1, on: controls)
        connection.signal()
        await Task.yield()
        XCTAssertEqual(controls.waitingCount, 1)
        controls.signal()
        await fulfillment(of: [resumed], timeout: 1)
        task.cancel()
    }

    @MainActor
    func testCancelledBeforeRegistrationNeverLeavesAWaiter() async {
        let signal = RouteWakeSignal(), done = expectation(description: "Cancelled before start")
        let task = Task { await signal.wait(after: signal.revision); done.fulfill() }
        task.cancel()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(signal.waitingCount, 0)
    }
}

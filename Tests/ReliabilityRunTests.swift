import XCTest
@testable import SessionPresentation

final class ReliabilityRunTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)
    func testBatterySamplesConvertToWholePercentages() {
        XCTAssertEqual(ReliabilityRun.batteryPercent(level: 0), 0)
        XCTAssertEqual(ReliabilityRun.batteryPercent(level: 0.734), 73)
        XCTAssertEqual(ReliabilityRun.batteryPercent(level: 0.736), 74)
        XCTAssertEqual(ReliabilityRun.batteryPercent(level: 1), 100)
    }
    func testUnknownOrInvalidBatterySamplesStayUnknown() {
        let invalidLevels: [Float] = [-1, -0.01, 1.01, .nan, .infinity, -.infinity]
        for level in invalidLevels {
            XCTAssertNil(ReliabilityRun.batteryPercent(level: level))
        }
    }

    func testRegularConfirmationsHaveNoGaps() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false)
        for second in stride(from: 5, through: 60, by: 5) {
            run.confirm(at: start.addingTimeInterval(Double(second)), battery: 79, charging: false)
        }
        run.finish(at: start.addingTimeInterval(61), battery: 78, charging: false)
        XCTAssertEqual(run.gapCount, 0)
        XCTAssertEqual(run.duration, 61)
        XCTAssertEqual(run.batteryDrop, 2)
        XCTAssertEqual(run.confirmations, 12)
    }
    func testSuspensionGapIsCountedBeforeNewConfirmation() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false)
        run.confirm(at: start.addingTimeInterval(60), battery: 78, charging: false)
        XCTAssertEqual(run.gapCount, 1)
        XCTAssertEqual(run.unconfirmedSeconds, 48)
        XCTAssertNil(run.gapStartedAt)
    }
    func testRepeatedObservationsDoNotDoubleCountGap() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: nil, charging: false)
        for second in 12...40 { run.observe(now: start.addingTimeInterval(Double(second)), battery: nil, charging: false) }
        run.finish(at: start.addingTimeInterval(42), battery: nil, charging: false)
        XCTAssertEqual(run.gapCount, 1)
        XCTAssertEqual(run.unconfirmedSeconds, 30)
        XCTAssertNil(run.batteryDrop)
    }
    func testFailureStartsGapImmediatelyAndChargingSuppressesBatteryDrop() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 40, charging: false)
        run.failed(at: start.addingTimeInterval(1), battery: 40, charging: false)
        run.failed(at: start.addingTimeInterval(2), battery: 40, charging: false)
        run.confirm(at: start.addingTimeInterval(5), battery: 41, charging: true)
        XCTAssertEqual(run.failedCommands, 2)
        XCTAssertEqual(run.gapCount, 1)
        XCTAssertEqual(run.unconfirmedSeconds, 4)
        XCTAssertNil(run.batteryDrop)
    }
    func testRelaunchEndsAtLastSavedObservationWithoutInventingRuntime() throws {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false)
        run.observe(now: start.addingTimeInterval(20), battery: 79, charging: false)
        var restored = try JSONDecoder().decode(ReliabilityRun.self, from: JSONEncoder().encode(run))
        restored.endAfterRelaunch()
        XCTAssertFalse(restored.running)
        XCTAssertTrue(restored.interrupted)
        XCTAssertEqual(restored.duration, 20)
        XCTAssertEqual(restored.unconfirmedSeconds, 8)
        restored.confirm(at: start.addingTimeInterval(200), battery: 50, charging: false)
        XCTAssertEqual(restored.duration, 20)
    }
    func testClockGoingBackwardDoesNotCreateNegativeTime() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false)
        run.observe(now: start.addingTimeInterval(-5), battery: 70, charging: false)
        XCTAssertEqual(run.duration, 0)
        XCTAssertEqual(run.latestBattery, 80)
    }

    private var configuration: ReliabilityConfiguration {
        ReliabilityConfiguration(appVersion: "2.3.1 (39)", activity: .heldLocation,
                                 findMyEnabled: true, liveActivityEnabled: true)
    }

    func testLifecycleCountsPreviousStateAndSuspensionWithoutDoubleCounting() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false, configuration: configuration)
        run.observe(now: start.addingTimeInterval(10), battery: 80, charging: false, appActive: false)
        run.observe(now: start.addingTimeInterval(10), battery: 80, charging: false, appActive: false)
        run.confirm(at: start.addingTimeInterval(310), battery: 78, charging: false, appActive: true)
        run.finish(at: start.addingTimeInterval(320), battery: 78, charging: false)
        XCTAssertEqual(run.usage?.inAppSeconds, 20)
        XCTAssertEqual(run.usage?.awaySeconds, 300)
        XCTAssertEqual(run.duration, 320)
        XCTAssertEqual(run.gapCount, 1)
    }

    func testLowPowerTransitionAndBackwardClockPreserveDurations() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false)
        run.observe(now: start.addingTimeInterval(10), battery: 80, charging: false, lowPower: true)
        run.observe(now: start.addingTimeInterval(5), battery: 75, charging: false, appActive: false, lowPower: false)
        run.observe(now: start.addingTimeInterval(30), battery: 79, charging: false, lowPower: false)
        run.finish(at: start.addingTimeInterval(40), battery: 79, charging: false)
        XCTAssertEqual(run.usage?.lowPowerSeconds, 20)
        XCTAssertEqual(run.usage?.inAppSeconds, 40)
        XCTAssertEqual(run.usage?.awaySeconds, 0)
    }

    func testMissingFinalBatteryDoesNotReuseAnEarlierReading() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false)
        run.observe(now: start.addingTimeInterval(60), battery: 79, charging: false)
        run.finish(at: start.addingTimeInterval(120), battery: nil, charging: false)
        XCTAssertNil(run.latestBattery)
        XCTAssertNil(run.batteryDrop)
    }

    func testConfigurationChangeStaysMarkedAfterChangingBack() {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false, configuration: configuration)
        var changed = configuration
        changed.findMyEnabled = false
        run.observe(now: start.addingTimeInterval(1), battery: 80, charging: false, configuration: changed)
        run.confirm(at: start.addingTimeInterval(2), battery: 80, charging: false, configuration: configuration)
        XCTAssertEqual(run.configuration, configuration)
        XCTAssertEqual(run.usage?.configurationChanged, true)
    }

    func testLegacyResultLoadsWithoutInventingUsageOrConfiguration() throws {
        let original = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "usage")
        json.removeValue(forKey: "configuration")
        var restored = try JSONDecoder().decode(ReliabilityRun.self, from: JSONSerialization.data(withJSONObject: json))
        restored.endAfterRelaunch()
        XCTAssertNil(restored.usage)
        XCTAssertNil(restored.configuration)
        XCTAssertTrue(restored.interrupted)
        XCTAssertEqual(restored.startedAt, start)
    }

    func testRelaunchDoesNotExtendUsageBeyondSavedObservation() throws {
        var run = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false)
        run.observe(now: start.addingTimeInterval(10), battery: 80, charging: false, appActive: false)
        run.observe(now: start.addingTimeInterval(30), battery: 79, charging: false)
        var restored = try JSONDecoder().decode(ReliabilityRun.self, from: JSONEncoder().encode(run))
        restored.endAfterRelaunch()
        restored.observe(now: start.addingTimeInterval(1000), battery: 40, charging: false, appActive: true)
        XCTAssertEqual(restored.usage?.inAppSeconds, 10)
        XCTAssertEqual(restored.usage?.awaySeconds, 20)
        XCTAssertEqual(restored.duration, 30)
    }

    func testArchiveBoundsDeduplicatesAndRoundTrips() throws {
        var history = ReliabilityHistory()
        for offset in 0..<12 {
            let date = start.addingTimeInterval(Double(offset * 2000))
            var run = ReliabilityRun(now: date, confirmedAt: date, battery: 80, charging: false, configuration: configuration)
            history.record(run)
            XCTAssertFalse(history.runs.contains { $0.id == run.id })
            run.finish(at: date.addingTimeInterval(1200), battery: 78, charging: false)
            history.record(run)
            history.record(run)
        }
        XCTAssertEqual(history.runs.count, 8)
        XCTAssertEqual(history.runs.first?.startedAt, start.addingTimeInterval(22000))
        XCTAssertEqual(history.runs.last?.startedAt, start.addingTimeInterval(8000))
        XCTAssertEqual(try JSONDecoder().decode(ReliabilityHistory.self, from: JSONEncoder().encode(history)), history)
        history.remove(id: start.addingTimeInterval(22000))
        XCTAssertEqual(history.runs.count, 7)
    }

    func testComparisonExplainsChargingAndDifferentConditions() {
        var a = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false, configuration: configuration)
        a.finish(at: start.addingTimeInterval(1200), battery: 78, charging: false)
        var changed = configuration
        changed.activity = .route
        var b = ReliabilityRun(now: start.addingTimeInterval(2000), confirmedAt: nil, battery: 80,
                               charging: true, appActive: false, lowPower: true, configuration: changed)
        b.finish(at: start.addingTimeInterval(3800), battery: 82, charging: true)
        let notes = ReliabilityHistory.comparisonNotes(a, b)
        XCTAssertTrue(notes.contains { $0.contains("Charging") })
        XCTAssertTrue(notes.contains { $0.contains("durations differ") })
        XCTAssertTrue(notes.contains { $0.contains("options differ") })
        XCTAssertTrue(notes.contains { $0.contains("inside Shift differs") })
        XCTAssertTrue(notes.contains { $0.contains("Low Power Mode") })
    }

    func testMatchingLongRunsHaveNoComparabilityWarnings() {
        var a = ReliabilityRun(now: start, confirmedAt: start, battery: 80, charging: false, configuration: configuration)
        a.finish(at: start.addingTimeInterval(1200), battery: 78, charging: false)
        var b = ReliabilityRun(now: start.addingTimeInterval(2000), confirmedAt: nil, battery: 70, charging: false, configuration: configuration)
        b.finish(at: start.addingTimeInterval(3200), battery: 67, charging: false)
        XCTAssertTrue(ReliabilityHistory.comparisonNotes(a, b).isEmpty)
    }
}

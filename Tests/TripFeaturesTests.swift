import XCTest
@testable import SessionPresentation

final class TripFeaturesTests: XCTestCase {
    private let a = RoutePoint(latitude: 0, longitude: 0)
    private let b = RoutePoint(latitude: 0, longitude: 0.01)
    private let c = RoutePoint(latitude: 0.01, longitude: 0.01)

    func testAccelerationAndBrakingAreBounded() {
        let first = RouteMotion.step(speed: 0, target: 15, remaining: 1000, mode: .eBike, smooth: true)
        XCTAssertEqual(first.speed, 0.65, accuracy: 0.0001)
        XCTAssertEqual(first.metres, 0.1625, accuracy: 0.0001)
        let slower = RouteMotion.step(speed: 15, target: 1, remaining: 1000, mode: .eBike, smooth: true)
        XCTAssertEqual(slower.speed, 14.1, accuracy: 0.0001)
    }
    func testCruiseNeverRandomlyOverspeedsAndInstantOptionIsExact() {
        let step = RouteMotion.step(speed: 10, target: 10, remaining: 1000, mode: .drive, smooth: true)
        XCTAssertEqual(step.speed, 10)
        XCTAssertEqual(step.metres, 5)
        let instant = RouteMotion.step(speed: 0, target: 10, remaining: 1000, mode: .drive, smooth: false)
        XCTAssertEqual(instant.metres, 5)
        XCTAssertEqual(instant.speed, 10)
    }
    func testMotionCannotOvershootStopOrCatchUpSuspendedTime() {
        let step = RouteMotion.step(speed: 30, target: 0, remaining: 0.1, mode: .drive, smooth: true, seconds: 300)
        XCTAssertEqual(step.metres, 0.1)
        XCTAssertEqual(step.speed, 0)
        let delayed = RouteMotion.step(speed: 10, target: 10, remaining: 1000, mode: .drive, smooth: true, seconds: 300)
        XCTAssertEqual(delayed.metres, 5)
        XCTAssertEqual(RouteMotion.step(speed: .nan, target: 10, remaining: 1000, mode: .drive, smooth: true).metres, 0)
    }
    func testCornerAndDestinationLowerTargetSpeed() throws {
        let track = try XCTUnwrap(RouteTrack([a, b, c]))
        let motion = RouteMotion(track: track)
        let corner = track.cumulative[1]
        XCTAssertLessThan(motion.target(cruise: 15, position: corner - 3, stopAt: track.length, mode: .eBike), 12)
        XCTAssertLessThan(motion.target(cruise: 15, position: track.length - 1, stopAt: track.length, mode: .eBike), 2)
        XCTAssertEqual(motion.target(cruise: 15, position: 0, stopAt: track.length, mode: .eBike), 15)
    }
    func testSmoothPlaybackActuallyReachesDestination() throws {
        let track = try XCTUnwrap(RouteTrack([a, b, c]))
        let motion = RouteMotion(track: track)
        var position = 0.0, speed = 0.0
        for _ in 0..<6000 {
            let target = motion.target(cruise: 10, position: position, stopAt: track.length, mode: .eBike)
            let step = RouteMotion.step(speed: speed, target: target, remaining: track.length - position, mode: .eBike, smooth: true)
            position += step.metres
            speed = step.speed
            if position == track.length { break }
        }
        XCTAssertEqual(position, track.length, accuracy: 0.001)
        XCTAssertEqual(speed, 0)
    }
    func testStopsDoNotResetOnRepeatedArrivalAndCountOnlyBoundedTicks() {
        let stop = RouteStop(name: "Cafe", metres: 100, waitSeconds: 60)
        var progress = RouteStopProgress()
        progress.arrive(stop)
        progress.tick(0.5)
        progress.arrive(stop)
        XCTAssertEqual(progress.remainingSeconds, 59.5)
        progress.tick(300)
        XCTAssertEqual(progress.remainingSeconds, 59)
        progress.tick(.nan)
        XCTAssertEqual(progress.remainingSeconds, 59)
    }
    func testContinueNowCompletesExactlyOneStop() {
        let first = RouteStop(name: "A", metres: 100, waitSeconds: 60)
        let second = RouteStop(name: "B", metres: 200, waitSeconds: 120)
        var progress = RouteStopProgress()
        progress.arrive(first)
        progress.finish()
        XCTAssertEqual(progress.next(in: [first, second])?.id, second.id)
        XCTAssertNil(progress.currentID)
        XCTAssertEqual(progress.remainingWait(in: [first, second]), 120)
    }
    func testSubMinuteStopsFinishAtTheirExactDuration() {
        for seconds in [1.0, 15, 30, 59, 60, 90] {
            let stop = RouteStop(name: "Short stop", metres: 100, waitSeconds: seconds)
            var progress = RouteStopProgress()
            progress.arrive(stop)
            for _ in 0..<(Int(seconds * 2) - 1) { progress.tick(0.5) }
            XCTAssertEqual(progress.remainingSeconds, 0.5)
            XCTAssertEqual(progress.currentID, stop.id)
            progress.tick(0.5)
            XCTAssertEqual(progress.remainingSeconds, 0)
            XCTAssertNil(progress.next(in: [stop]))
        }
    }
    func testShortStopsSurviveSavingAndDurationLabelsKeepSeconds() throws {
        var original = trip()
        original.stops[0].waitSeconds = 15
        let restored = try JSONDecoder().decode(SavedTrip.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(restored.stops[0].waitSeconds, 15)
        XCTAssertEqual(StopDuration.label(0), "Pass through")
        XCTAssertEqual(StopDuration.label(15), "15 sec")
        XCTAssertEqual(StopDuration.label(90), "1 min 30 sec")
        XCTAssertEqual(StopDuration.normalized(-1), 0)
        XCTAssertEqual(StopDuration.normalized(.nan), 0)
        XCTAssertEqual(StopDuration.normalized(5000), 5000)
        XCTAssertEqual(StopDuration.normalized(86_401), 86_400)
    }
    func testFullDayStopSurvivesSavingRecoveryAndAwakeCountdown() throws {
        var original = trip()
        original.stops[0].waitSeconds = 86_400
        let restored = try JSONDecoder().decode(SavedTrip.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(restored.stops, original.stops)
        var progress = RouteStopProgress()
        progress.arrive(restored.stops[0])
        progress.tick(10_000) // Suspension cannot silently consume hours.
        XCTAssertEqual(progress.remainingSeconds, 86_399.5)
        let recovered = try JSONDecoder().decode(RouteStopProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(recovered, progress)
        XCTAssertTrue(recovered.isValid(for: restored.stops, at: 100))
        for _ in 0..<172_798 { progress.tick(0.5) }
        XCTAssertEqual(progress.remainingSeconds, 0.5)
        progress.tick(0.5)
        XCTAssertNil(progress.next(in: restored.stops))
    }
    func testZeroWaitAndCompletedStopsDoNotLoopForever() {
        let stop = RouteStop(name: "Pass", metres: 100, waitSeconds: 0)
        var progress = RouteStopProgress()
        progress.arrive(stop)
        progress.arrive(stop)
        XCTAssertNil(progress.next(in: [stop]))
        XCTAssertNil(progress.currentID)
    }
    func testSeekSkipsEarlierStopsAndRewindsFutureStops() {
        let stops = [RouteStop(name: "A", metres: 100, waitSeconds: 60), RouteStop(name: "B", metres: 200, waitSeconds: 60)]
        var progress = RouteStopProgress()
        progress.seek(to: 200, stops: stops)
        XCTAssertEqual(progress.next(in: stops)?.id, stops[1].id)
        progress.seek(to: 50, stops: stops)
        XCTAssertEqual(progress.next(in: stops)?.id, stops[0].id)
        progress.seek(to: 300, stops: stops)
        XCTAssertNil(progress.next(in: stops))
    }
    func testUndoRestoresWaitSnapshotAndExpires() {
        let stop = RouteStop(name: "Cafe", metres: 100, waitSeconds: 60)
        let id = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        var progress = RouteStopProgress()
        progress.arrive(stop)
        progress.tick(0.5)
        let undo = RouteJumpUndo(routeID: id, metres: 100, wasPaused: true, stops: progress, expiresAt: now.addingTimeInterval(15))
        progress.seek(to: 500, stops: [stop])
        XCTAssertEqual(undo.stops.remainingSeconds, 59.5)
        XCTAssertTrue(undo.wasPaused)
        XCTAssertTrue(undo.isValid(routeID: id, now: now.addingTimeInterval(14)))
        XCTAssertFalse(undo.isValid(routeID: id, now: now.addingTimeInterval(15)))
        XCTAssertFalse(undo.isValid(routeID: UUID(), now: now))
        XCTAssertFalse(undo.isValid(routeID: nil, now: now))
    }
    private func trip() -> SavedTrip {
        SavedTrip(name: "Home via cafe", mode: .eBike, speedMPH: 35, smoothMovement: true,
                  originName: "Start", destinationName: "Home", points: [a, b, c],
                  source: .walkingForCycling(fallback: true), instructions: [],
                  stops: [RouteStop(name: "Cafe", metres: 100, waitSeconds: 120)], calculatedAt: Date())
    }
    func testSavedTripRoundTripsGeometryModeSpeedProvenanceAndStops() throws {
        let original = trip()
        XCTAssertTrue(original.isValid)
        let restored = try JSONDecoder().decode(SavedTrip.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored.isValid)
    }
    func testSavedTripRejectsUnknownVersionInvalidGeometryAndSpeed() {
        var value = trip()
        value.version = 2
        XCTAssertFalse(value.isValid)
        value = trip(); value.points = [a, a]
        XCTAssertFalse(value.isValid)
        value = trip(); value.speedMPH = .nan
        XCTAssertFalse(value.isValid)
        value = trip(); value.speedMPH = 36
        XCTAssertFalse(value.isValid)
    }
    func testSavedTripRejectsUnorderedDuplicateOrOutOfBoundsStops() {
        var value = trip()
        value.stops.append(RouteStop(name: "Earlier", metres: 50, waitSeconds: 60))
        XCTAssertFalse(value.isValid)
        value = trip(); value.stops.append(value.stops[0])
        XCTAssertFalse(value.isValid)
        value = trip(); value.stops[0].metres = 100_000
        XCTAssertFalse(value.isValid)
        value = trip(); value.stops[0].waitSeconds = -1
        XCTAssertFalse(value.isValid)
    }
    func testActivePayloadRequiresFreshEvidenceEvenWithMissingOrWrongExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = SessionSnapshot(phase: .active, startedAt: now, lastConfirmedAt: now,
                                    expiresAt: nil, place: nil, lowPower: false)
        XCTAssertEqual(state.presentedPhase(at: now.addingTimeInterval(12)), .unverified)
        state.expiresAt = now.addingTimeInterval(3600)
        XCTAssertEqual(state.presentedPhase(at: now.addingTimeInterval(60)), .unverified)
        state.lastConfirmedAt = nil
        XCTAssertEqual(state.presentedPhase(at: now), .unverified)
        state.lastConfirmedAt = now.addingTimeInterval(1)
        XCTAssertEqual(state.presentedPhase(at: now), .unverified)
    }
}

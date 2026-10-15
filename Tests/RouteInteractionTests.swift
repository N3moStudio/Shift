import XCTest
@testable import SessionPresentation

final class RouteInteractionTests: XCTestCase {
    private let a = RoutePoint(latitude: 0, longitude: 0)
    private let b = RoutePoint(latitude: 0, longitude: 0.01)
    private let c = RoutePoint(latitude: 0.01, longitude: 0.01)

    func testTrackRejectsInvalidAndStationaryPaths() {
        XCTAssertNil(RouteTrack([]))
        XCTAssertNil(RouteTrack([a, a]))
        XCTAssertNil(RouteTrack([a, RoutePoint(latitude: 91, longitude: 0)]))
        XCTAssertNil(RouteTrack([a, RoutePoint(latitude: .nan, longitude: 0)]))
    }

    func testDistanceCursorFollowsCornersAndClampsEndpoints() throws {
        let track = try XCTUnwrap(RouteTrack([a, a, b, c]))
        XCTAssertEqual(track.points.count, 3)
        XCTAssertEqual(track.point(at: -1), a)
        XCTAssertEqual(track.point(at: track.length + 100), c)
        XCTAssertEqual(track.point(at: .nan), a)
        let bend = track.point(at: track.cumulative[1])
        XCTAssertEqual(bend.latitude, b.latitude, accuracy: 0.000001)
        XCTAssertEqual(bend.longitude, b.longitude, accuracy: 0.000001)
        let afterBend = track.point(at: track.cumulative[1] + 100)
        XCTAssertEqual(afterBend.longitude, b.longitude, accuracy: 0.000001)
        XCTAssertGreaterThan(afterBend.latitude, 0)
    }

    func testMarkerSnapsOntoPathAndCanMoveBackwards() throws {
        let track = try XCTUnwrap(RouteTrack([a, b, c]))
        let nearStart = try XCTUnwrap(track.nearest(to: RoutePoint(latitude: -0.001, longitude: 0.002)))
        let nearFinish = try XCTUnwrap(track.nearest(to: RoutePoint(latitude: 0.008, longitude: 0.011)))
        XCTAssertEqual(nearStart.point.latitude, 0, accuracy: 0.000001)
        XCTAssertEqual(nearFinish.point.longitude, 0.01, accuracy: 0.000001)
        XCTAssertLessThan(nearStart.metres, nearFinish.metres)
        var progress = JourneyProgress(totalMetres: track.length)
        progress.confirmPosition(nearFinish.metres)
        progress.confirmPosition(nearStart.metres)
        XCTAssertEqual(progress.travelledMetres, nearStart.metres)
        XCTAssertGreaterThan(progress.remainingMetres, track.length / 2)
    }

    func testCrossingUsesNearestProgressToResolveTie() throws {
        let track = try XCTUnwrap(RouteTrack([a, b, a]))
        let early = try XCTUnwrap(track.nearest(to: a, preferredDistance: 0))
        let late = try XCTUnwrap(track.nearest(to: a, preferredDistance: track.length))
        XCTAssertEqual(early.metres, 0, accuracy: 0.001)
        XCTAssertEqual(late.metres, track.length, accuracy: 0.001)
    }

    func testAntimeridianUsesShortSegment() throws {
        let track = try XCTUnwrap(RouteTrack([RoutePoint(latitude: 0, longitude: 179.99), RoutePoint(latitude: 0, longitude: -179.99)]))
        XCTAssertLessThan(track.length, 2300)
        XCTAssertGreaterThan(abs(track.point(at: track.length / 2).longitude), 179.99)
    }

    func testMarkerExpiresAndCannotApplyToReplacementRoute() {
        let id = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let marker = RouteSeek(routeID: id, metres: 100, expiresAt: now.addingTimeInterval(30))
        XCTAssertTrue(marker.isValid(routeID: id, now: now.addingTimeInterval(29)))
        XCTAssertFalse(marker.isValid(routeID: id, now: now.addingTimeInterval(30)))
        XCTAssertFalse(marker.isValid(routeID: UUID(), now: now))
        XCTAssertFalse(marker.isValid(routeID: nil, now: now))
        XCTAssertFalse(RouteSeek(routeID: id, metres: .nan, expiresAt: now.addingTimeInterval(30)).isValid(routeID: id, now: now))
    }

    func testWalkingFallbackHasExplicitProvenanceAndNeverClaimsDrivingRoute() {
        let fallback = RoutePathSource.walkingForCycling(fallback: true)
        for mode in [TravelMode.cycle, .eBike] {
            XCTAssertTrue(fallback.supports(mode))
            XCTAssertTrue(fallback.playbackNote(mode: mode)?.contains("Cycling unavailable") == true)
        }
        XCTAssertFalse(fallback.supports(.drive))
        XCTAssertEqual(fallback.pathNetwork, .walking)
        XCTAssertTrue(fallback.isAutomatic)
        XCTAssertTrue(RoutePathSource.walkingForCycling(fallback: false).playbackNote(mode: .eBike)?.contains("Cycling unavailable") == false)
    }

    func testOnlyCarBoundaryRequiresChoiceAndSpeedOnlyPathRemainsLabeled() {
        let nonCar: [TravelMode] = [.walk, .run, .cycle, .eBike]
        for first in nonCar {
            for second in nonCar { XCTAssertFalse(first.needsRouteChoice(changingTo: second)) }
            XCTAssertTrue(first.needsRouteChoice(changingTo: .drive))
            XCTAssertTrue(TravelMode.drive.needsRouteChoice(changingTo: first))
        }
        XCTAssertFalse(TravelMode.drive.needsRouteChoice(changingTo: .drive))
        XCTAssertNotNil(RoutePathSource.apple(.walking).playbackNote(mode: .drive))
    }

    func testEveryModeSpeedIsFiniteBoundedAndEBikeStillAllowsOneToThirtyFive() {
        for mode in TravelMode.allCases {
            XCTAssertEqual(mode.clampedSpeedMPH(.nan), mode.defaultSpeedMPH)
            XCTAssertEqual(mode.clampedSpeedMPH(-1), mode.speedRangeMPH.lowerBound)
            XCTAssertEqual(mode.clampedSpeedMPH(1000), mode.speedRangeMPH.upperBound)
        }
        XCTAssertEqual(TravelMode.eBike.speedRangeMPH, 1...35)
        XCTAssertEqual(TravelMode.cycle.routeNetwork, TravelMode.eBike.routeNetwork)
    }

    func testFreehandUndoRedoTreatsEachStrokeAsOneEdit() {
        var drawing = RouteDrawing()
        drawing.append(a)
        drawing.beginStroke()
        drawing.append(b)
        drawing.append(c)
        drawing.endStroke()
        XCTAssertEqual(drawing.points, [a, b, c])
        drawing.undo()
        XCTAssertEqual(drawing.points, [a])
        drawing.redo()
        XCTAssertEqual(drawing.points, [a, b, c])
        drawing.clear()
        XCTAssertTrue(drawing.points.isEmpty)
        drawing.undo()
        XCTAssertEqual(drawing.points, [a, b, c])
    }

    func testDrawingRejectsNoiseAndNewEditInvalidatesRedo() {
        var drawing = RouteDrawing()
        drawing.append(a)
        drawing.append(a)
        drawing.append(RoutePoint(latitude: .infinity, longitude: 0))
        XCTAssertEqual(drawing.points, [a])
        drawing.append(b)
        drawing.undo()
        XCTAssertTrue(drawing.canRedo)
        drawing.append(c)
        XCTAssertFalse(drawing.canRedo)
        XCTAssertEqual(drawing.points, [a, c])
    }

    func testDrawingDistanceStaysCorrectThroughStrokeUndoRedoAndClear() {
        var drawing = RouteDrawing()
        drawing.append(a)
        XCTAssertEqual(drawing.distance, 0)
        drawing.beginStroke()
        drawing.append(b)
        drawing.append(c)
        drawing.endStroke()
        let total = a.distance(to: b) + b.distance(to: c)
        XCTAssertEqual(drawing.distance, total, accuracy: 0.000001)
        drawing.undo()
        XCTAssertEqual(drawing.distance, 0)
        drawing.redo()
        XCTAssertEqual(drawing.distance, total, accuracy: 0.000001)
        drawing.clear()
        XCTAssertEqual(drawing.distance, 0)
        drawing.undo()
        XCTAssertEqual(drawing.distance, total, accuracy: 0.000001)
    }

    func testDrawingDistanceSurvivesPointEditingAndCancelledStroke() {
        var drawing = RouteDrawing()
        drawing.append(a)
        drawing.append(b)
        let beforeStroke = drawing
        drawing.beginStroke()
        drawing.append(c)
        drawing = beforeStroke // Matches cancellation when a second finger joins.
        XCTAssertEqual(drawing.distance, a.distance(to: b), accuracy: 0.000001)
        drawing.replacePoints([a, c])
        XCTAssertEqual(drawing.distance, a.distance(to: c), accuracy: 0.000001)
        drawing.undo()
        XCTAssertEqual(drawing.distance, a.distance(to: b), accuracy: 0.000001)
        drawing.append(b) // A repeated point must not increase the cached length.
        drawing.append(RoutePoint(latitude: .infinity, longitude: 0))
        XCTAssertEqual(drawing.distance, a.distance(to: b), accuracy: 0.000001)
    }

    func testSeekingHidesETAButKeepsProgressUntilConfirmation() {
        var progress = JourneyProgress(totalMetres: 1000)
        progress.confirmPosition(300)
        progress.state = .seeking
        XCTAssertNil(progress.remainingSeconds(speed: 10, fresh: true))
        XCTAssertEqual(progress.travelledMetres, 300)
        progress.confirmPosition(100)
        progress.state = .paused
        XCTAssertEqual(progress.remainingMetres, 900)
        XCTAssertNil(progress.remainingSeconds(speed: 10, fresh: true))
        progress.state = .moving
        XCTAssertEqual(progress.remainingSeconds(speed: 10, fresh: true), 90)
    }
}

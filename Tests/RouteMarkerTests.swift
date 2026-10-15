import XCTest
@testable import SessionPresentation

final class RouteMarkerTests: XCTestCase {
    private func screen(_ x: Double, _ y: Double) -> RouteScreenPoint { RouteScreenPoint(x: x, y: y) }

    func testContinuousDragVisitsPointsBetweenVerticesOnDenseCurves() throws {
        let points = (0...80).map { screen(Double($0) * 4, sin(Double($0) / 8) * 40) }
        let segments = (1..<points.count).map { index in
            RouteScreenSegment(start: points[index - 1], end: points[index],
                startMetres: Double(index - 1) * 10, endMetres: Double(index) * 10)
        }
        var previous = 0.0
        for index in segments.indices {
            for fraction in [0.15, 0.5, 0.85] {
                let segment = segments[index]
                let query = screen(segment.start.x + (segment.end.x - segment.start.x) * fraction,
                                   segment.start.y + (segment.end.y - segment.start.y) * fraction)
                let result = try XCTUnwrap(RouteScreenSnap.closest(to: query, segments: segments, preferredDistance: previous))
                XCTAssertEqual(result.metres, segment.startMetres + fraction * 10, accuracy: 0.000001)
                XCTAssertLessThan(result.distance, 0.000001)
                previous = result.metres
            }
        }
    }

    func testDragPassesCornerInBothDirectionsWithoutSticking() throws {
        let segments = [
            RouteScreenSegment(start: screen(0, 100), end: screen(100, 100), startMetres: 0, endMetres: 1000),
            RouteScreenSegment(start: screen(100, 100), end: screen(100, 0), startMetres: 1000, endMetres: 2000)
        ]
        let after = try XCTUnwrap(RouteScreenSnap.closest(to: screen(100, 98), segments: segments, preferredDistance: 990))
        XCTAssertEqual(after.metres, 1020, accuracy: 0.000001)
        XCTAssertEqual(after.point, screen(100, 98))
        let before = try XCTUnwrap(RouteScreenSnap.closest(to: screen(98, 100), segments: segments, preferredDistance: after.metres))
        XCTAssertEqual(before.metres, 980, accuracy: 0.000001)
        XCTAssertEqual(before.point, screen(98, 100))
    }

    func testRotatedScreenProjectionUsesSameCursorAsVisibleAndAcceptedPoint() throws {
        let track = try XCTUnwrap(RouteTrack([
            RoutePoint(latitude: 60, longitude: 12), RoutePoint(latitude: 60.02, longitude: 12.02)
        ]))
        let first = track.points[0], last = track.points[1]
        // A flat map's Mercator coordinates undergo scale, rotation and translation.
        func project(_ point: RoutePoint) -> RouteScreenPoint {
            let x = (point.longitude - first.longitude) * .pi / 180 * 100_000
            let y = (point.mercatorY - first.mercatorY) * 100_000
            return screen(200 + x * 0.6 - y * 0.8, 300 + x * 0.8 + y * 0.6)
        }
        let start = project(first), end = project(last)
        let query = screen(start.x + (end.x - start.x) * 0.63, start.y + (end.y - start.y) * 0.63)
        let snap = try XCTUnwrap(RouteScreenSnap.closest(to: query, segments: [
            RouteScreenSegment(start: start, end: end, startMetres: 0, endMetres: track.length)
        ], preferredDistance: 0))
        let accepted = RouteSeek(routeID: UUID(), metres: snap.metres, expiresAt: .distantFuture)
        let annotation = project(track.point(at: accepted.metres))
        XCTAssertEqual(snap.metres, track.length * 0.63, accuracy: 0.000001)
        XCTAssertEqual(annotation.x, snap.point.x, accuracy: 0.000001)
        XCTAssertEqual(annotation.y, snap.point.y, accuracy: 0.000001)
    }

    func testCrossingKeepsPreferredTraversalOnlyForSubpixelTies() throws {
        let repeated = [
            RouteScreenSegment(start: screen(0, 0), end: screen(100, 0), startMetres: 0, endMetres: 100),
            RouteScreenSegment(start: screen(100, 0), end: screen(0, 0), startMetres: 100, endMetres: 200)
        ]
        let outbound = try XCTUnwrap(RouteScreenSnap.closest(to: screen(25, 0), segments: repeated, preferredDistance: 0))
        let inbound = try XCTUnwrap(RouteScreenSnap.closest(to: screen(25, 0), segments: repeated, preferredDistance: 200))
        XCTAssertEqual(outbound.metres, 25)
        XCTAssertEqual(inbound.metres, 175)
    }

    func testScreenSnappingRejectsMalformedAndCollapsedSegments() {
        let segments = [
            RouteScreenSegment(start: screen(0, 0), end: screen(0, 0), startMetres: 0, endMetres: 100),
            RouteScreenSegment(start: screen(0, 0), end: screen(.nan, 2), startMetres: 0, endMetres: 100),
            RouteScreenSegment(start: screen(0, 0), end: screen(10, 2), startMetres: 100, endMetres: 0)
        ]
        XCTAssertNil(RouteScreenSnap.closest(to: screen(1, 1), segments: segments, preferredDistance: 0))
        XCTAssertNil(RouteScreenSnap.closest(to: screen(.infinity, 1), segments: [], preferredDistance: 0))
    }

    func testIndexFindsCornersAfterDuplicatePointsAreRemoved() throws {
        let a = RoutePoint(latitude: 0, longitude: 0)
        let b = RoutePoint(latitude: 0, longitude: 0.01)
        let c = RoutePoint(latitude: 0.01, longitude: 0.01)
        let track = try XCTUnwrap(RouteTrack([a, a, b, b, c]))
        let index = RouteSnapIndex(track: track)
        for query in [RoutePoint(latitude: 0.00002, longitude: 0.01), RoutePoint(latitude: 0, longitude: 0.00998)] {
            let expected = try XCTUnwrap(track.nearest(to: query))
            let actual = try XCTUnwrap(index.nearest(to: query))
            XCTAssertEqual(actual.metres, expected.metres, accuracy: 0.000001)
            XCTAssertTrue(index.candidateSegments(near: query, preferredDistance: track.length).contains(actual.segmentIndex))
        }
    }

    func testIndexPreservesPreferredTraversalOnAnOverlappingReturnPath() throws {
        let track = try XCTUnwrap(RouteTrack([
            RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0, longitude: 0.01), RoutePoint(latitude: 0, longitude: 0)
        ]))
        let index = RouteSnapIndex(track: track)
        let query = RoutePoint(latitude: 0, longitude: 0.0025)
        let early = try XCTUnwrap(index.nearest(to: query, preferredDistance: 0))
        let late = try XCTUnwrap(index.nearest(to: query, preferredDistance: track.length))
        XCTAssertEqual(early.metres, track.length / 8, accuracy: 0.000001)
        XCTAssertEqual(late.metres, track.length * 7 / 8, accuracy: 0.000001)
    }

    func testIndexHandlesBothSidesOfDateLineAndShortWrappedSegments() throws {
        let track = try XCTUnwrap(RouteTrack([
            RoutePoint(latitude: 1, longitude: 179.99), RoutePoint(latitude: 1, longitude: -179.99),
            RoutePoint(latitude: 1.01, longitude: -179.99)
        ]))
        let index = RouteSnapIndex(track: track)
        for query in [RoutePoint(latitude: 1.00001, longitude: 179.995), RoutePoint(latitude: 1.00001, longitude: -179.995),
                      RoutePoint(latitude: 1.005, longitude: -179.99001)] {
            let expected = try XCTUnwrap(track.nearest(to: query))
            let actual = try XCTUnwrap(index.nearest(to: query))
            XCTAssertEqual(actual.metres, expected.metres, accuracy: 0.00001)
        }
    }

    func testIndexedLongRouteMatchesExhaustiveNearestSearch() throws {
        let points = (0..<5000).map { index in
            RoutePoint(latitude: 37 + sin(Double(index) / 20) * 0.002, longitude: -122 + Double(index) * 0.00001)
        }
        let track = try XCTUnwrap(RouteTrack(points))
        let index = RouteSnapIndex(track: track)
        for sample in [5, 350, 1800, 3700, 4980] {
            let query = points[sample].interpolated(to: points[sample + 1], fraction: 0.4)
            let actual = try XCTUnwrap(index.nearest(to: query))
            let expected = try XCTUnwrap(track.nearest(to: query))
            XCTAssertEqual(actual.metres, expected.metres, accuracy: 0.00001)
            let candidates = index.candidateSegments(near: query, preferredDistance: 0)
            XCTAssertTrue(candidates.contains(actual.segmentIndex))
            XCTAssertLessThanOrEqual(candidates.count, 6)
        }
    }
}

import XCTest
@testable import SessionPresentation

final class NamedAreaTests: XCTestCase {
    private func square(_ name: String = "Campus", low: Double = 0, high: Double = 0.01) -> NamedArea {
        NamedArea(name: name, points: [RoutePoint(latitude: low, longitude: low), RoutePoint(latitude: low, longitude: high),
            RoutePoint(latitude: high, longitude: high), RoutePoint(latitude: high, longitude: low)])
    }
    func testInsideOutsideAndBoundary() {
        let area = square()
        XCTAssertTrue(area.isValid)
        XCTAssertTrue(area.contains(RoutePoint(latitude: 0.005, longitude: 0.005)))
        XCTAssertTrue(area.contains(RoutePoint(latitude: 0, longitude: 0.005)))
        XCTAssertTrue(area.contains(RoutePoint(latitude: 0.01, longitude: 0.01)))
        XCTAssertFalse(area.contains(RoutePoint(latitude: -0.001, longitude: 0.005)))
        XCTAssertFalse(area.contains(RoutePoint(latitude: .nan, longitude: 0)))
    }
    func testSmallestContainingAreaWinsIndependentlyOfOrder() {
        let campus = square(), hall = square("Hall", low: 0.002, high: 0.004)
        let inside = RoutePoint(latitude: 0.003, longitude: 0.003)
        XCTAssertEqual(NamedArea.name(at: inside, in: [campus, hall]), "Hall")
        XCTAssertEqual(NamedArea.name(at: inside, in: [hall, campus]), "Hall")
        XCTAssertEqual(NamedArea.name(at: RoutePoint(latitude: 0.006, longitude: 0.006), in: [campus, hall]), "Campus")
        XCTAssertNil(NamedArea.name(at: RoutePoint(latitude: 2, longitude: 2), in: [campus, hall]))
    }
    func testConcaveAreaDoesNotNameItsCutout() {
        let area = NamedArea(name: "L shape", points: [(0.0, 0.0), (0, 3), (1, 3), (1, 1), (3, 1), (3, 0)].map {
            RoutePoint(latitude: $0.0, longitude: $0.1)
        })
        XCTAssertTrue(area.contains(RoutePoint(latitude: 0.5, longitude: 2)))
        XCTAssertFalse(area.contains(RoutePoint(latitude: 2, longitude: 2)))
    }
    func testAreaAcrossDateLineIsLocal() {
        let area = NamedArea(name: "Across date line", points: [RoutePoint(latitude: 0, longitude: 179.99), RoutePoint(latitude: 0, longitude: -179.99),
            RoutePoint(latitude: 0.01, longitude: -179.99), RoutePoint(latitude: 0.01, longitude: 179.99)])
        XCTAssertTrue(area.isValid)
        XCTAssertTrue(area.contains(RoutePoint(latitude: 0.005, longitude: 180)))
        XCTAssertTrue(area.contains(RoutePoint(latitude: 0.005, longitude: -180)))
        XCTAssertFalse(area.contains(RoutePoint(latitude: 0.005, longitude: 0)))
    }
    func testRejectsEmptyFlatAndOutOfRangeAreas() {
        XCTAssertFalse(NamedArea(name: " ", points: square().points).isValid)
        XCTAssertFalse(NamedArea(name: "Empty", points: []).isValid)
        XCTAssertFalse(NamedArea(name: "Line", points: (0..<3).map { RoutePoint(latitude: 0, longitude: Double($0)) }).isValid)
        XCTAssertFalse(NamedArea(name: "Invalid", points: [RoutePoint(latitude: 99, longitude: 0)] + square().points).isValid)
        XCTAssertFalse(NamedArea(name: "Crossed", points: [(0.0, 0.0), (2, 2), (0, 2), (1, 0)].map { RoutePoint(latitude: $0.0, longitude: $0.1) }).isValid)
    }
    func testOldCoordinateLabelsGetReadablePlaceholder() {
        XCTAssertEqual(PlaceLabel.readable("37.12345, -122.12345"), "Saved place")
        XCTAssertEqual(PlaceLabel.readable("Coffee, bakery"), "Coffee, bakery")
        XCTAssertEqual(PlaceLabel.readable(" School "), "School")
    }
}

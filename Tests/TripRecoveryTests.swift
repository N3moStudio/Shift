import XCTest
@testable import SessionPresentation

final class TripRecoveryTests: XCTestCase {
    func testCheckpointRoundTripRetainsRemainingWaitAndSettings() throws {
        var trip = fixtureTrip()
        let stop = RouteStop(name: "Wait", metres: 10, waitSeconds: 60)
        trip.stops = [stop]
        var progress = RouteStopProgress()
        progress.arrive(stop)
        progress.tick(0.5)
        let date = Date(timeIntervalSince1970: 1000)
        let checkpoint = TripCheckpoint(trip: trip, metres: 10, stops: progress, confirmedAt: date, savedAt: date, arrival: .repeatTrip)
        XCTAssertTrue(checkpoint.isValid)
        let decoded = try JSONDecoder().decode(TripCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(decoded, checkpoint)
        XCTAssertEqual(decoded.stops.remainingSeconds, 59.5)
        XCTAssertEqual(decoded.trip.speedMPH, 15)
    }
    func testRejectsProgressOffRouteAndUnknownStop() {
        let date = Date(timeIntervalSince1970: 1000)
        var checkpoint = TripCheckpoint(trip: fixtureTrip(), metres: -1, stops: RouteStopProgress(), confirmedAt: date, savedAt: date, arrival: .stay)
        XCTAssertFalse(checkpoint.isValid)
        checkpoint.metres = 1_000_000
        XCTAssertFalse(checkpoint.isValid)
        checkpoint.metres = 10
        checkpoint.stops.arrive(RouteStop(name: "Unknown", metres: 10, waitSeconds: 0))
        XCTAssertFalse(checkpoint.isValid)
    }
    func testRejectsWaitAtDifferentPositionAndCompletedFutureStop() {
        let stop = RouteStop(name: "Wait", metres: 10, waitSeconds: 60)
        var progress = RouteStopProgress()
        progress.arrive(stop)
        XCTAssertFalse(progress.isValid(for: [stop], at: 11))
        progress.finish()
        XCTAssertFalse(progress.isValid(for: [stop], at: 9))
        XCTAssertTrue(progress.isValid(for: [stop], at: 10))
    }
    func testOldTripsWithoutNewFieldsStillDecode() throws {
        let data = try JSONEncoder().encode(fixtureTrip())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "folder")
        json.removeValue(forKey: "arrival")
        let decoded = try JSONDecoder().decode(SavedTrip.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.isValid)
        XCTAssertNil(decoded.arrival)
        XCTAssertNil(decoded.folder)
    }
    func testPanelNormalizationRemovesDuplicatesAndKeepsThree() {
        XCTAssertEqual(PanelShortcut.normalized([]), PanelShortcut.defaults)
        XCTAssertEqual(PanelShortcut.normalized([.speed, .pause, .speed, .saved, .settings]), [.speed, .pause, .saved])
    }
    func testRemovedSaverNeverAppearsInPanelChoices() {
        XCTAssertFalse(PanelShortcut.allCases.contains(.batterySaver))
        XCTAssertEqual(PanelShortcut.normalized([.saved, .batterySaver, .settings]), [.saved, .settings])
        XCTAssertEqual(PanelShortcut.normalized([.batterySaver]), PanelShortcut.defaults)
    }
}

func fixtureTrip() -> SavedTrip {
    SavedTrip(name: "Example", mode: .eBike, speedMPH: 15, smoothMovement: false,
        originName: "A", destinationName: "B",
        points: [RoutePoint(latitude: 40, longitude: -75), RoutePoint(latitude: 40.01, longitude: -75)],
        source: .drawn, instructions: [], stops: [], calculatedAt: Date(timeIntervalSince1970: 1000))
}

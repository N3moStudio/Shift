import XCTest
@testable import SessionPresentation

final class RouteEditingTests: XCTestCase {
    private func sections() -> [RouteTravelSection] {
        [RouteTravelSection(id: UUID(), startMetres: 0, endMetres: 100, mode: .walk, speedMPH: 3),
         RouteTravelSection(id: UUID(), startMetres: 100, endMetres: 300, mode: .eBike, speedMPH: 20)]
    }
    func testSectionValidationRejectsGapsOverlapDuplicatesAndInvalidSpeed() {
        let valid = sections()
        XCTAssertTrue(RouteTravelSection.valid(valid, length: 300))
        XCTAssertFalse(RouteTravelSection.valid([], length: 300))
        var changed = valid; changed[1].startMetres = 110
        XCTAssertFalse(RouteTravelSection.valid(changed, length: 300))
        changed = valid; changed[1].startMetres = 90
        XCTAssertFalse(RouteTravelSection.valid(changed, length: 300))
        changed = valid; changed[1].id = changed[0].id
        XCTAssertFalse(RouteTravelSection.valid(changed, length: 300))
        changed = valid; changed[1].speedMPH = 36
        XCTAssertFalse(RouteTravelSection.valid(changed, length: 300))
        changed = valid; changed[0].endMetres = .nan
        XCTAssertFalse(RouteTravelSection.valid(changed, length: 300))
        XCTAssertFalse(RouteTravelSection.valid(valid, length: 301))
    }
    func testSectionBoundaryAndBackwardSeekSelectMatchingMode() {
        let values = sections()
        XCTAssertEqual(RouteTravelSection.current(in: values, at: 0)?.mode, .walk)
        XCTAssertEqual(RouteTravelSection.current(in: values, at: 99)?.mode, .walk)
        XCTAssertEqual(RouteTravelSection.current(in: values, at: 100)?.mode, .eBike)
        XCTAssertEqual(RouteTravelSection.current(in: values, at: 300)?.mode, .eBike)
        XCTAssertEqual(RouteTravelSection.current(in: values, at: 25)?.mode, .walk)
        XCTAssertNil(RouteTravelSection.current(in: values, at: .nan))
    }
    func testETAUsesEachSectionAndCurrentSectionOverride() {
        let values = sections()
        let expected = 50 / (3 * 0.44704) + 200 / (20 * 0.44704)
        XCTAssertEqual(RouteTravelSection.remainingSeconds(values, from: 50), expected, accuracy: 0.0001)
        let overridden = RouteTravelSection.remainingSeconds(values, from: 50, overrides: [values[0].id: 6])
        XCTAssertEqual(overridden, 50 / (6 * 0.44704) + 200 / (20 * 0.44704), accuracy: 0.0001)
        XCTAssertEqual(RouteTravelSection.remainingSeconds(values, from: 400), 0)
    }
    func testPreviewIsStationaryUntilPlayedAndAfterPause() {
        var preview = RouteRehearsal()
        preview.advance(seconds: 0.1, length: 100, speed: 10, sections: [], stops: [])
        XCTAssertEqual(preview.metres, 0)
        preview.isPlaying = true; preview.rate = 1
        preview.advance(seconds: 0.1, length: 100, speed: 10, sections: [], stops: [])
        XCTAssertEqual(preview.metres, 1, accuracy: 0.0001)
        preview.isPlaying = false
        preview.advance(seconds: 0.1, length: 100, speed: 10, sections: [], stops: [])
        XCTAssertEqual(preview.metres, 1, accuracy: 0.0001)
    }
    func testPreviewHandlesStopAndSkipThenFinishesAtDestination() {
        var preview = RouteRehearsal(); preview.isPlaying = true; preview.rate = 100
        let stop = RouteStop(name: "A", metres: 10, waitSeconds: 60)
        preview.advance(seconds: 0.1, length: 30, speed: 10, sections: [], stops: [stop])
        XCTAssertEqual(preview.metres, 10)
        XCTAssertEqual(preview.waitingID, stop.id)
        XCTAssertEqual(preview.waitingSeconds, 51, accuracy: 0.0001)
        preview.skipWait()
        preview.advance(seconds: 0.1, length: 30, speed: 10, sections: [], stops: [stop])
        XCTAssertEqual(preview.metres, 30)
        XCTAssertFalse(preview.isPlaying)
        preview.reset()
        XCTAssertEqual(preview.metres, 0)
        XCTAssertTrue(preview.completedStops.isEmpty)
        XCTAssertNil(preview.waitingID)
    }
    func testPreviewRespectsMultipleModeBoundariesInOneTick() {
        var preview = RouteRehearsal(); preview.isPlaying = true; preview.rate = 100
        let values = [RouteTravelSection(id: UUID(), startMetres: 0, endMetres: 1, mode: .walk, speedMPH: 3),
                      RouteTravelSection(id: UUID(), startMetres: 1, endMetres: 1000, mode: .eBike, speedMPH: 20)]
        preview.advance(seconds: 0.1, length: 1000, speed: 1, sections: values, stops: [])
        let expected = 1 + (10 - 1 / (3 * 0.44704)) * 20 * 0.44704
        XCTAssertEqual(preview.metres, expected, accuracy: 0.0001)
    }
    func testPreviewBoundsSuspendedTimeAndRejectsInvalidValues() {
        var preview = RouteRehearsal(); preview.isPlaying = true; preview.rate = 1
        preview.advance(seconds: 300, length: 1000, speed: 10, sections: [], stops: [])
        XCTAssertEqual(preview.metres, 2.5)
        preview.advance(seconds: .nan, length: 1000, speed: 10, sections: [], stops: [])
        preview.advance(seconds: 0.1, length: 1000, speed: .nan, sections: [], stops: [])
        XCTAssertEqual(preview.metres, 2.5)
    }
    func testPreviewHandlesCoincidentZeroWaitStopsWithoutStalling() {
        var preview = RouteRehearsal(); preview.isPlaying = true; preview.rate = 100
        let stops = [RouteStop(name: "A", metres: 10, waitSeconds: 0), RouteStop(name: "B", metres: 10, waitSeconds: 0)]
        preview.advance(seconds: 0.1, length: 30, speed: 10, sections: [], stops: stops)
        XCTAssertEqual(preview.metres, 30)
        XCTAssertEqual(preview.completedStops.count, 2)
    }
    func testPreviewSeekPausesAndRearmsStopsWhenMovingBackwards() {
        let stops = [RouteStop(name: "A", metres: 10, waitSeconds: 15), RouteStop(name: "B", metres: 20, waitSeconds: 30)]
        var preview = RouteRehearsal()
        preview.isPlaying = true
        preview.rate = 50
        preview.seek(to: 25, length: 40, stops: stops)
        XCTAssertFalse(preview.isPlaying)
        XCTAssertEqual(preview.completedStops, Set(stops.map(\.id)))
        XCTAssertEqual(preview.rate, 50)
        preview.seek(to: 5, length: 40, stops: stops)
        XCTAssertTrue(preview.completedStops.isEmpty)
        XCTAssertNil(preview.waitingID)
        preview.isPlaying = true
        preview.rate = 1
        preview.advance(seconds: 0.25, length: 40, speed: 20, sections: [], stops: stops)
        XCTAssertEqual(preview.metres, 10)
        XCTAssertEqual(preview.waitingID, stops[0].id)
        XCTAssertEqual(preview.waitingSeconds, 15)
    }
    func testPreviewSeekToStopRestoresWaitAndDoesNotAdvanceUntilPlayed() {
        let stop = RouteStop(name: "Stop", metres: 10, waitSeconds: 15)
        var preview = RouteRehearsal()
        preview.seek(to: 10, length: 40, stops: [stop])
        XCTAssertEqual(preview.waitingID, stop.id)
        XCTAssertEqual(preview.waitingSeconds, 15)
        preview.advance(seconds: 0.25, length: 40, speed: 10, sections: [], stops: [stop])
        XCTAssertEqual(preview.waitingSeconds, 15)
        preview.isPlaying = true
        preview.rate = 1
        preview.advance(seconds: 0.25, length: 40, speed: 10, sections: [], stops: [stop])
        XCTAssertEqual(preview.waitingSeconds, 14.75)
        preview.seek(to: 10, length: 40, stops: [stop])
        XCTAssertEqual(preview.waitingSeconds, 15)
    }
    func testPreviewRestoresFullDayWaitAndPausesIt() {
        let stop = RouteStop(name: "Long stop", metres: 10, waitSeconds: 86_400)
        var preview = RouteRehearsal()
        preview.seek(to: 10, length: 40, stops: [stop])
        preview.advance(seconds: 0.25, length: 40, speed: 10, sections: [], stops: [stop])
        XCTAssertEqual(preview.waitingSeconds, 86_400)
        preview.isPlaying = true
        preview.rate = 1
        preview.advance(seconds: 0.25, length: 40, speed: 10, sections: [], stops: [stop])
        XCTAssertEqual(preview.waitingSeconds, 86_399.75)
        preview.seek(to: 10, length: 40, stops: [stop])
        XCTAssertEqual(preview.waitingSeconds, 86_400)
    }
    func testPreviewSeekClampsEndpointsAndRejectsNonFiniteInputs() {
        var preview = RouteRehearsal()
        preview.seek(to: 500, length: 100, stops: [])
        XCTAssertEqual(preview.metres, 100)
        preview.seek(to: .nan, length: 100, stops: [])
        preview.seek(to: 5, length: .infinity, stops: [])
        preview.seek(to: 5, length: 0, stops: [])
        XCTAssertEqual(preview.metres, 100)
        preview.seek(to: -5, length: 100, stops: [])
        XCTAssertEqual(preview.metres, 0)
    }
    func testPreviewSeekPreservesCoincidentStopsAndDestinationWait() {
        let stops = [RouteStop(name: "A", metres: 10, waitSeconds: 0), RouteStop(name: "B", metres: 10, waitSeconds: 1)]
        var preview = RouteRehearsal()
        preview.seek(to: 10, length: 10, stops: stops)
        XCTAssertEqual(preview.waitingID, stops[0].id)
        preview.rate = 10
        preview.isPlaying = true
        preview.advance(seconds: 0.1, length: 10, speed: 10, sections: [], stops: stops)
        XCTAssertEqual(preview.completedStops, Set(stops.map(\.id)))
        XCTAssertFalse(preview.isPlaying)
        XCTAssertNil(preview.waitingID)
    }
    func testSavedTripsDecodeOlderFilesAndRoundTripSectionSettings() throws {
        let points = [RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0, longitude: 0.01)]
        let track = try XCTUnwrap(RouteTrack(points))
        var trip = SavedTrip(name: "Example", mode: .walk, speedMPH: 3, smoothMovement: false,
            originName: "A", destinationName: "B", points: points, source: .apple(.walking),
            instructions: [], stops: [], calculatedAt: Date())
        let oldData = try JSONEncoder().encode(trip)
        let oldRestored = try JSONDecoder().decode(SavedTrip.self, from: oldData)
        XCTAssertNil(oldRestored.travelSections)
        XCTAssertTrue(oldRestored.isValid)
        trip.travelSections = [RouteTravelSection(id: RouteLegChoice.destinationID, startMetres: 0,
            endMetres: track.length, mode: .eBike, speedMPH: 35)]
        let restored = try JSONDecoder().decode(SavedTrip.self, from: JSONEncoder().encode(trip))
        XCTAssertEqual(trip, restored)
        XCTAssertTrue(restored.isValid)
        trip.travelSections?[0].endMetres = track.length / 2
        XCTAssertFalse(trip.isValid)
    }
    func testMixedModeSourceRequiresVerifiedSectionsOrExplicitStoredMode() {
        XCTAssertFalse(RoutePathSource.mixedModes.supports(.drive))
        XCTAssertFalse(RoutePathSource.mixedModes.supports(.walk))
        XCTAssertTrue(RoutePathSource.mixedModes.isAutomatic)
        XCTAssertNotNil(RoutePathSource.mixedModes.playbackNote(mode: .walk))
    }
}

import XCTest
@testable import SessionPresentation

final class TripEditHistoryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private func trip(_ name: String = "Café ride") -> SavedTrip {
        SavedTrip(name: name, mode: .eBike, speedMPH: 12, smoothMovement: false,
            originName: "Home", destinationName: "College",
            points: [RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0, longitude: 0.01)],
            source: .drawn, instructions: [], stops: [RouteStop(name: "Library", metres: 100, waitSeconds: 60)],
            calculatedAt: date, savedAt: date, folder: "Weekdays")
    }

    func testLegacyLibraryLoadsWithoutChangingSavedTripIdentity() throws {
        let old = trip()
        let migrated = try TripLibraryDocument.decode(JSONEncoder().encode([old]))
        XCTAssertEqual(migrated.trips, [old])
        XCTAssertTrue(migrated.revisions.isEmpty)
        XCTAssertEqual(try TripLibraryDocument.decode(migrated.encoded()), migrated)
    }

    func testOnlyLastThreePreviousVersionsAreKeptPerTrip() throws {
        var current = trip("Version 0")
        var library = TripLibraryDocument(trips: [current])
        for i in 1...5 {
            current.name = "Version \(i)"
            library = try library.updating(to: [current], reason: .name, now: date.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(library.revisions.map { $0.trip.name }, ["Version 4", "Version 3", "Version 2"])
        XCTAssertTrue(library.isValid)
        XCTAssertEqual(try TripLibraryDocument.decode(library.encoded()), library)
    }

    func testUnchangedSaveDoesNotConsumeHistoryAndNewCopyStartsEmpty() throws {
        let old = trip()
        var same = old; same.savedAt = date.addingTimeInterval(60)
        var copy = same; copy.id = UUID(); copy.name += " copy"
        let library = try TripLibraryDocument(trips: [old]).updating(to: [same, copy], reason: .route)
        XCTAssertTrue(library.revisions.isEmpty)
    }

    func testRestoreBringsBackCompleteRouteAndCanBeUndone() throws {
        let original = trip()
        var edited = original
        edited.name = "Changed ride"; edited.destinationName = "Park"; edited.originName = "Shop"
        edited.points.append(RoutePoint(latitude: 0.01, longitude: 0.01))
        edited.stops[0].name = "New stop"; edited.stops[0].waitSeconds = 180
        edited.mode = .walk; edited.speedMPH = 3; edited.smoothMovement = true
        edited.folder = "Weekend"; edited.arrival = .stay
        let library = try TripLibraryDocument(trips: [original]).updating(to: [edited], reason: .route, now: date)
        let revision = try XCTUnwrap(library.revisions.first)
        let restored = try library.restoring(revision.id, tripID: original.id, expected: edited, now: date.addingTimeInterval(10))
        XCTAssertTrue(try XCTUnwrap(restored.trips.first).hasSameSavedContent(as: original))
        XCTAssertEqual(restored.revisions.first?.reason, .restore)
        XCTAssertEqual(restored.revisions.first?.trip, edited)
        let undo = try restored.restoring(XCTUnwrap(restored.revisions.first).id, tripID: original.id,
            expected: XCTUnwrap(restored.trips.first), now: date.addingTimeInterval(20))
        XCTAssertTrue(try XCTUnwrap(undo.trips.first).hasSameSavedContent(as: edited))
    }

    func testRestoreRejectsStalePreviewAndOtherTrip() throws {
        let original = trip()
        var edited = original; edited.name = "Edited"
        let library = try TripLibraryDocument(trips: [original]).updating(to: [edited], reason: .name)
        let revision = try XCTUnwrap(library.revisions.first)
        XCTAssertThrowsError(try library.restoring(revision.id, tripID: original.id, expected: original))
        XCTAssertThrowsError(try library.restoring(revision.id, tripID: UUID(), expected: edited))
        XCTAssertThrowsError(try library.restoring(UUID(), tripID: original.id, expected: edited))
        XCTAssertEqual(library.trips, [edited])
    }

    func testDeletingATripPrunesOnlyItsVersions() throws {
        let first = trip("First"), second = trip("Second")
        var changedFirst = first, changedSecond = second
        changedFirst.name = "Changed first"; changedSecond.name = "Changed second"
        let edited = try TripLibraryDocument(trips: [first, second]).updating(to: [changedFirst, changedSecond], reason: .name)
        let deleted = try edited.updating(to: [changedSecond], reason: .route)
        XCTAssertEqual(deleted.revisions.map { $0.trip.id }, [second.id])
    }

    func testCorruptOrDuplicateLibraryIsRejected() throws {
        let item = trip()
        XCTAssertThrowsError(try TripLibraryDocument.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try TripLibraryDocument(trips: [item, item]).encoded())
        var bad = item; bad.points = []
        XCTAssertThrowsError(try TripLibraryDocument(trips: [item]).updating(to: [bad], reason: .path))
        let orphan = TripRevision(replacedAt: date, reason: .path, trip: item)
        XCTAssertThrowsError(try TripLibraryDocument(trips: [], revisions: [orphan]).encoded())
    }

    func testSearchFindsNamesFolderStopsAndEndpointsWithoutAccentsOrCase() {
        let value = trip()
        XCTAssertTrue(SavedNameSearch.matches("CAFE", trip: value))
        XCTAssertTrue(SavedNameSearch.matches(" home   library ", trip: value))
        XCTAssertTrue(SavedNameSearch.matches("college weekdays", trip: value))
        XCTAssertFalse(SavedNameSearch.matches("cafe airport", trip: value))
        XCTAssertTrue(SavedNameSearch.matches("", trip: value))
        XCTAssertTrue(SavedNameSearch.matches("school", fields: ["My School", "Places"]))
        XCTAssertFalse(SavedNameSearch.matches("park", fields: ["My School", "Places"]))
    }
}

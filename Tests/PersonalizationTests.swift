import XCTest
@testable import SessionPresentation

final class PersonalizationTests: XCTestCase {
    func testOldPlaceBackupDecodesWithoutAppearanceFields() throws {
        let data = Data(#"{"name":"Home","latitude":40,"longitude":-75,"folder":"Weekdays"}"#.utf8)
        let place = try JSONDecoder().decode(BackupPlace.self, from: data)
        XCTAssertTrue(place.isValid)
        XCTAssertNil(place.icon)
        XCTAssertNil(place.color)
        XCTAssertEqual(place.folder, "Weekdays")
    }

    func testStyledPlacesSurviveBackupAndRecentlyDeleted() throws {
        let place = BackupPlace(name: "School", latitude: 40, longitude: -75,
            folder: "Weekdays", icon: SavedPlaceSymbol.school.rawValue, color: SavedPlaceTint.purple.rawValue)
        let backup = LibraryBackup(places: [place], trips: [], preferences: nil).selecting([.places])
        XCTAssertEqual(try LibraryBackup.decode(backup.encoded()).places, [place])
        let deleted = DeletedLibraryItem(payload: .place(place))
        XCTAssertEqual(try JSONDecoder().decode(DeletedLibraryItem.self, from: JSONEncoder().encode(deleted)), deleted)
        var older = place
        older.icon = nil; older.color = nil
        XCTAssertEqual(try LibraryMerge.places(local: [place], incoming: [older]), [place])
    }

    func testAppearanceMetadataIsBoundedBeforeImport() {
        var place = BackupPlace(name: "Home", latitude: 40, longitude: -75)
        place.icon = String(repeating: "x", count: 65)
        XCTAssertFalse(place.isValid)
        place.icon = nil
        place.color = String(repeating: "x", count: 33)
        XCTAssertFalse(place.isValid)
    }

    func testDuplicateKeepsTheWholeTripAndLeavesOriginalIndependent() throws {
        var original = fixtureTrip()
        original.name = "School ride"
        original.folder = "Weekdays"
        original.arrival = .stay
        let track = try XCTUnwrap(RouteTrack(original.points))
        original.stops = [RouteStop(name: "Meet here", metres: track.length / 2, waitSeconds: 90)]
        original.travelSections = [RouteTravelSection(id: UUID(), startMetres: 0,
            endMetres: track.length, mode: original.mode, speedMPH: original.speedMPH)]
        let now = Date(timeIntervalSince1970: 9000)
        var copy = original.duplicated(existingNames: [original.name], now: now)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.savedAt, now)
        XCTAssertEqual(copy.name, "School ride (copy)")
        var comparison = copy
        comparison.id = original.id; comparison.name = original.name; comparison.savedAt = original.savedAt
        XCTAssertEqual(comparison, original)
        XCTAssertTrue(copy.isValid)
        copy.stops[0].name = "Changed copy"
        copy.points[0] = RoutePoint(latitude: 1, longitude: 1)
        XCTAssertEqual(original.stops[0].name, "Meet here")
        XCTAssertNotEqual(original.points[0], copy.points[0])
    }

    func testDuplicateNamesAreDistinctAndFitTheLibraryLimit() {
        var trip = fixtureTrip()
        trip.name = "Ride"
        XCTAssertEqual(trip.duplicated(existingNames: ["Ride", "RIDE (COPY)", "Ride (copy 2)"]).name, "Ride (copy 3)")
        trip.name = String(repeating: "a", count: 120)
        let copy = trip.duplicated(existingNames: [trip.name])
        XCTAssertLessThanOrEqual(copy.name.count, 120)
        XCTAssertTrue(copy.isValid)
    }

    func testSettingsSearchFindsEverydayAliasesAndMultipleWords() {
        XCTAssertEqual(SettingsDestination.results(for: "LOCK SCREEN"), [.activity])
        XCTAssertEqual(SettingsDestination.results(for: "dynamic island"), [.activity])
        XCTAssertEqual(SettingsDestination.results(for: "developer logs"), [.diagnostics])
        XCTAssertEqual(SettingsDestination.results(for: "liquid glass"), [.appearance])
        XCTAssertEqual(SettingsDestination.results(for: "face id"), [.privacy])
        XCTAssertTrue(SettingsDestination.results(for: "life360").contains(.experimental))
        XCTAssertTrue(SettingsDestination.results(for: "remote find my").contains(.remoteFindMy))
        XCTAssertTrue(SettingsDestination.results(for: "   ").isEmpty)
        XCTAssertTrue(SettingsDestination.results(for: "no such preference").isEmpty)
    }
}

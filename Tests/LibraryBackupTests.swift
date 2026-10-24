import XCTest
@testable import SessionPresentation

final class LibraryBackupTests: XCTestCase {
    private func fixture() -> LibraryBackup {
        LibraryBackup(places: [BackupPlace(name: "Example", latitude: 40, longitude: -75, folder: "Trips")], trips: [fixtureTrip()],
            preferences: BackupPreferences(usualSpeeds: ["eBike": 20], glassPanel: true, appearance: "dark", smoothMovement: false,
                preferWalkingPaths: true, shortcuts: [.saved, .speed, .pause]))
    }
    func testRoundTripPreservesLibraryAndPreferences() throws {
        let backup = fixture()
        let restored = try LibraryBackup.decode(backup.encoded())
        XCTAssertEqual(restored.places, backup.places)
        XCTAssertEqual(restored.trips, backup.trips)
        XCTAssertEqual(restored.preferences, backup.preferences)
    }
    func testUnitPreferenceRoundTripsWithoutReinterpretingLegacySpeeds() throws {
        var backup = fixture()
        XCTAssertNil(try LibraryBackup.decode(backup.encoded()).preferences?.speedUnit)
        backup.preferences?.speedUnit = .kilometersPerHour
        backup.trips[0].stops = [RouteStop(name: "Quick stop", metres: 100, waitSeconds: 15)]
        let restored = try LibraryBackup.decode(backup.encoded())
        XCTAssertEqual(restored.preferences?.speedUnit, .kilometersPerHour)
        XCTAssertEqual(restored.preferences?.usualSpeeds, backup.preferences?.usualSpeeds)
        XCTAssertEqual(restored.trips, backup.trips)
    }
    func testShiftExportsKeepOlderLibraryFilesReadable() throws {
        var backup = fixture()
        XCTAssertEqual(backup.format, "Shift library")
        backup.format = "Locus library"
        XCTAssertEqual(try LibraryBackup.decode(JSONEncoder().encode(backup)).places, backup.places)
    }
    func testFullDayStopsSurviveBackupAndRejectOutOfRangeImports() throws {
        var backup = fixture()
        backup.trips[0].stops = [RouteStop(name: "Long stop", metres: 100, waitSeconds: 86_400)]
        let restored = try LibraryBackup.decode(backup.encoded())
        XCTAssertEqual(restored.trips[0].stops, backup.trips[0].stops)
        backup.trips[0].stops[0].waitSeconds = 86_401
        XCTAssertThrowsError(try LibraryBackup.decode(JSONEncoder().encode(backup)))
    }
    func testRepeatedImportPreservesLocalChangesWithoutDuplicates() throws {
        var local = fixtureTrip()
        var incoming = local
        local.name = "My local edit"
        incoming.name = "Old backup"
        XCTAssertEqual(try LibraryMerge.trips(local: [local], incoming: [incoming, incoming]), [local])
        let place = fixture().places[0]
        XCTAssertEqual(try LibraryMerge.places(local: [place], incoming: [place]), [place])
    }
    func testRejectsInvalidCoordinatesVersionAndSpeed() throws {
        var backup = fixture()
        backup.places[0].latitude = 95
        XCTAssertThrowsError(try backup.encoded())
        backup = fixture(); backup.version = 99
        XCTAssertThrowsError(try LibraryBackup.decode(JSONEncoder().encode(backup)))
        backup = fixture(); backup.preferences?.usualSpeeds = ["eBike": 200]
        XCTAssertFalse(backup.isValid)
        backup = fixture(); backup.preferences?.usualSpeeds = ["not-a-mode": 5]
        XCTAssertFalse(backup.isValid)
    }
    func testRejectsDuplicateIDsAndCorruptInput() throws {
        var backup = fixture()
        backup.trips.append(backup.trips[0])
        XCTAssertFalse(backup.isValid)
        XCTAssertThrowsError(try LibraryBackup.decode(Data("not json".utf8)))
    }
    func testRejectsMergeOverCapacityBeforeWriting() {
        let trips = (0..<50).map { _ in fixtureTrip() }
        XCTAssertThrowsError(try LibraryMerge.trips(local: trips, incoming: [fixtureTrip()]))
    }
    func testBackupHasOnlyExplicitTopLevelFields() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture().encoded()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["format", "version", "createdAt", "places", "trips", "preferences"]))
        let preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
        XCTAssertEqual(Set(preferences.keys), Set(["usualSpeeds", "glassPanel", "appearance", "smoothMovement", "preferWalkingPaths", "shortcuts"]))
    }

    func testSettingsOnlyContainsNoLocationData() throws {
        var backup = fixture()
        backup.areas = [NamedArea(name: "Campus", points: [RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0, longitude: 1), RoutePoint(latitude: 1, longitude: 0)])]
        let selected = backup.selecting([.settings])
        let restored = try LibraryBackup.decode(selected.encoded())
        XCTAssertEqual(restored.included, [.settings])
        XCTAssertTrue(restored.places.isEmpty)
        XCTAssertTrue(restored.trips.isEmpty)
        XCTAssertNil(restored.areas)
        let text = String(decoding: try selected.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("latitude"))
        XCTAssertFalse(text.contains("Campus"))
    }

    func testPlacesOnlyKeepsAreaNamesButOmitsPreferencesAndTrips() throws {
        var backup = fixture()
        let area = NamedArea(name: "Campus", points: [RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0, longitude: 1), RoutePoint(latitude: 1, longitude: 0)])
        backup.areas = [area]
        let restored = try LibraryBackup.decode(backup.selecting([.places]).encoded())
        XCTAssertEqual(restored.areas, [area])
        XCTAssertEqual(restored.places, backup.places)
        XCTAssertTrue(restored.trips.isEmpty)
        XCTAssertNil(restored.preferences)
        XCTAssertEqual(try LibraryMerge.areas(local: [area], incoming: [area]), [area])
    }

    func testReadsVersionOneAndRejectsContradictorySelections() throws {
        var legacy = fixture()
        legacy.version = 1
        let restored = try LibraryBackup.decode(legacy.encoded())
        XCTAssertEqual(restored.included, Set(BackupCategory.allCases))
        XCTAssertNil(restored.areas)
        var contradictory = fixture()
        contradictory.categories = [.settings]
        XCTAssertThrowsError(try contradictory.encoded())
        XCTAssertThrowsError(try fixture().selecting([]).encoded())
    }

    func testLegacySaverBackupPreservesChoicesAndDropsRemovedShortcut() throws {
        var backup = fixture()
        backup.preferences?.display = displayFixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
        var settings = try XCTUnwrap(object["preferences"] as? [String: Any])
        var display = try XCTUnwrap(settings["display"] as? [String: Any])
        settings["shortcuts"] = ["saved", "batterySaver", "settings"]
        display["strongBatterySaver"] = true
        display["skipBatterySaverPrompt"] = true
        display["batterySaverExceptions"] = ["liveActivities", "glass"]
        display["activityBatterySaver"] = true
        display["activityBatteryThreshold"] = 80
        settings["display"] = display
        object["preferences"] = settings
        let restored = try LibraryBackup.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.preferences?.shortcuts, [.saved, .settings])
        XCTAssertEqual(restored.preferences?.glassPanel, true)
        XCTAssertEqual(restored.preferences?.display?.liveActivities, true)
        XCTAssertEqual(restored.preferences?.display?.mapStyle, 2)
        XCTAssertEqual(restored.places, backup.places)
        XCTAssertEqual(restored.trips, backup.trips)
        let reexport = String(decoding: try restored.encoded(), as: UTF8.self)
        XCTAssertFalse(reexport.contains("batterySaver"))
        XCTAssertFalse(reexport.contains("BatterySaver"))
        XCTAssertFalse(reexport.contains("activityBatteryThreshold"))
    }

    func testDisplayExportContainsOnlyCurrentControls() throws {
        let original = displayFixture()
        let data = try JSONEncoder().encode(original)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(fields["strongBatterySaver"])
        XCTAssertNil(fields["skipBatterySaverPrompt"])
        XCTAssertNil(fields["batterySaverExceptions"])
        XCTAssertNil(fields["activityBatterySaver"])
        XCTAssertNil(fields["activityBatteryThreshold"])
        let restored = try JSONDecoder().decode(BackupDisplayPreferences.self, from: data)
        XCTAssertEqual(restored, original)
    }

    func testSaverOnlyLegacyPanelFallsBackToNormalControls() throws {
        var backup = fixture()
        backup.preferences?.shortcuts = [.batterySaver]
        backup.preferences?.glassPanel = false
        backup.preferences?.display = displayFixture()
        backup.preferences?.display?.liveActivities = false
        let restored = try LibraryBackup.decode(backup.encoded())
        XCTAssertEqual(restored.preferences?.shortcuts, PanelShortcut.defaults)
        XCTAssertEqual(restored.preferences?.glassPanel, false)
        XCTAssertEqual(restored.preferences?.display?.liveActivities, false)
    }

    func testLegacyShortcutDoesNotBypassDuplicateValidation() throws {
        var backup = fixture()
        backup.preferences?.shortcuts = [.batterySaver, .saved, .saved]
        XCTAssertThrowsError(try LibraryBackup.decode(JSONEncoder().encode(backup)))
    }

    private func displayFixture() -> BackupDisplayPreferences {
        BackupDisplayPreferences(liveActivities: true, hideLocation: false, hideIslandLocation: false,
            lockScreenProgress: true, islandProgress: true, islandTimer: true,
            connectionAlerts: true, reminderMinutes: 0, saveRecentLocations: true,
            recentHistoryRetention: .forever, mapStyle: 2)
    }
}

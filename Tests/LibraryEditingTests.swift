import XCTest
@testable import SessionPresentation

final class LibraryEditingTests: XCTestCase {
    private let a = RoutePoint(latitude: 0, longitude: 0)
    private let b = RoutePoint(latitude: 0, longitude: 0.01)
    private let c = RoutePoint(latitude: 0.01, longitude: 0.01)
    func testDeletedItemExpiresExactlyAfterThirtyDays() {
        let date = Date(timeIntervalSince1970: 1000)
        let item = DeletedLibraryItem(deletedAt: date, payload: .place(BackupPlace(name: "Home", latitude: 0, longitude: 0)))
        XCTAssertTrue(item.isRetained(at: date.addingTimeInterval(DeletedLibraryItem.lifetime - 1)))
        XCTAssertFalse(item.isRetained(at: date.addingTimeInterval(DeletedLibraryItem.lifetime)))
    }
    func testDeletedPayloadRoundTripsWithIdentityAndFolder() throws {
        let place = BackupPlace(name: "Home", latitude: 0, longitude: 0, folder: "Weekends")
        let original = DeletedLibraryItem(payload: .place(place))
        let restored = try JSONDecoder().decode(DeletedLibraryItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
    }
    func testCancelledDragRestoresAllCoordinatesWithoutUndoFrame() {
        var edit = PointEditHistory([a, b])
        edit.move(0, to: c); edit.endDrag(cancelled: true)
        XCTAssertEqual(edit.points, [a, b]); XCTAssertFalse(edit.canUndo)
    }
    func testDragMakesOneUndoFrameAndNewEditClearsRedo() {
        var edit = PointEditHistory([a, b])
        edit.move(0, to: c); edit.move(1, to: a); edit.endDrag(cancelled: false)
        edit.undo(); XCTAssertEqual(edit.points, [a, b]); XCTAssertFalse(edit.canUndo)
        edit.redo(); XCTAssertEqual(edit.points, [c, a])
        edit.undo(); edit.replace([a, c, b]); XCTAssertFalse(edit.canRedo)
    }
    func testEditingRejectsInvalidPointsAndHandlesStaleIndex() {
        var edit = PointEditHistory([a, b])
        edit.move(90, to: c)
        edit.replace([a, RoutePoint(latitude: .nan, longitude: 0)])
        XCTAssertEqual(edit.points, [a, b])
    }
    func testDrawnEditKeepsIdentityWaitsAndSectionModes() throws {
        let track = try XCTUnwrap(RouteTrack([a, b]))
        let stop = RouteStop(name: "Cafe", metres: track.length / 2, waitSeconds: 90)
        let sections = [RouteTravelSection(id: UUID(), startMetres: 0, endMetres: track.length, mode: .eBike, speedMPH: 12)]
        let trip = SavedTrip(name: "Test trip", mode: .eBike, speedMPH: 12, smoothMovement: false,
            originName: "Start", destinationName: "Finish", points: [a, b], source: .drawn,
            instructions: [RouteInstruction(id: 0, text: "Old turn", endDistance: track.length)], stops: [stop], calculatedAt: Date(), travelSections: sections)
        let changed = try XCTUnwrap(DrawnPathEdit.replacing(trip, with: [a, c, b]))
        let length = try XCTUnwrap(RouteTrack(changed.points)).length
        XCTAssertEqual(changed.id, trip.id); XCTAssertEqual(changed.name, trip.name)
        XCTAssertEqual(changed.stops[0].id, stop.id); XCTAssertEqual(changed.stops[0].waitSeconds, 90)
        XCTAssertEqual(changed.stops[0].metres / length, 0.5, accuracy: 0.00001)
        XCTAssertEqual(changed.travelSections?.first?.mode, .eBike)
        XCTAssertTrue(changed.instructions.isEmpty); XCTAssertTrue(changed.isValid)
    }
    func testWidgetLinksRejectExtraActionsAndRoundTripIdentity() throws {
        let value = LocusShortcut(kind: .trip, id: UUID())
        XCTAssertEqual(value.url.scheme, "shift")
        XCTAssertEqual(LocusShortcut(url: value.url), value)
        XCTAssertEqual(LocusShortcut(url: URL(string: "locus://trip/\(value.id)")!), value)
        XCTAssertNil(LocusShortcut(url: URL(string: value.url.absoluteString + "?start=true")!))
        XCTAssertNil(LocusShortcut(url: URL(string: "locus://teleport/\(value.id)")!))
        XCTAssertNil(LocusShortcut(url: URL(string: "https://trip/\(value.id)")!))
    }
    func testWidgetReadsOnlyItsOwnProvisionedGroupNames() throws {
        let groups = ["group.other.app", WidgetLibrary.group + ".TEAM123", WidgetLibrary.group + "-unrelated"]
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["com.apple.security.application-groups": groups]], format: .xml, options: 0)
        let wrapped = Data([0, 1, 2]) + plist + Data([3, 4, 5])
        XCTAssertEqual(WidgetLibrary.groups(in: wrapped), [WidgetLibrary.group + ".TEAM123"])
        XCTAssertTrue(WidgetLibrary.groups(in: Data("broken".utf8)).isEmpty)
    }
}

import XCTest
@testable import SessionPresentation

final class SessionTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func event(_ kind: String, _ details: [String: String] = [:], after: Double = 0) -> DeveloperLogEvent {
        DeveloperLogEvent(time: start.addingTimeInterval(after), process: "test", event: kind, details: details)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-timeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func defaults() throws -> UserDefaults {
        let name = "Shift-timeline-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAcceptedWritesGroupWithoutHidingFailureOrPause() {
        var archive = SessionTimelineArchive(windowStart: start)
        archive.include(event("location_write_result", ["result": "accepted"]))
        archive.include(event("location_write_result", ["result": "accepted"], after: 1))
        archive.include(event("location_write_result", ["result": "failed"], after: 2))
        archive.include(event("route_state_changed", ["state": "paused"], after: 3))
        archive.include(event("location_write_result", ["result": "accepted"], after: 4))
        XCTAssertEqual(archive.entries.map(\.count), [2, 1, 1, 1])
        XCTAssertEqual(archive.entries[0].lastAt, start.addingTimeInterval(1))
        XCTAssertEqual(archive.entries[1].title, "Location update failed")
        XCTAssertEqual(archive.entries[2].title, "Route paused")
    }

    func testGroupsSplitAfterFiveMinutesAndHighlightCountIsBounded() {
        var archive = SessionTimelineArchive(windowStart: start)
        archive.include(event("location_write_result", ["result": "accepted"]))
        archive.include(event("location_write_result", ["result": "accepted"], after: 301))
        XCTAssertEqual(archive.entries.count, 2)
        for i in 0..<1100 { archive.include(event("problem_moment", ["marker": String(i)], after: Double(i + 302))) }
        XCTAssertEqual(archive.entries.count, 1000)
        XCTAssertTrue(archive.trimmed)
        XCTAssertTrue(archive.isValid)
    }

    func testNetworkAndRelaunchNeverClaimAirplaneModeOrForceCloseWasDetected() {
        var archive = SessionTimelineArchive(windowStart: start)
        archive.include(event("process_started"))
        archive.include(event("network_path_changed", ["monitor": "wifi", "status": "unsatisfied"]))
        XCTAssertTrue(archive.entries[0].detail.contains("unknown"))
        XCTAssertEqual(archive.entries[1].title, "Wi-Fi path unavailable")
        XCTAssertTrue(archive.entries[1].detail.contains("doesn't tell us"))
        XCTAssertFalse(archive.include(event("touch_ended")))
    }

    func testNoteKeepsOriginalMarkedTime() {
        var archive = SessionTimelineArchive(windowStart: start)
        archive.include(event("problem_moment", ["marker": "one"]))
        archive.include(event("problem_note", ["marker": "one", "note": "Stop failed"], after: 30))
        XCTAssertEqual(archive.entries.count, 1)
        XCTAssertEqual(archive.entries[0].firstAt, start)
        XCTAssertEqual(archive.entries[0].detail, "Stop failed")
    }

    func testBookmarkAndNotePersistInExportAndTimelineAfterRelaunch() async throws {
        let location = try folder(), prefs = try defaults(), date = start, marker = UUID()
        var first: DeveloperLogStore? = DeveloperLogStore(folder: location, defaults: prefs, now: { date })
        try await first?.markProblem(id: marker, at: date)
        try await first?.addProblemNote("Stop didn't respond", marker: marker)
        let output = try await XCTUnwrap(first).export()
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains(marker.uuidString))
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("Stop didn't respond"))
        first = nil
        let reopened = DeveloperLogStore(folder: location, defaults: prefs, now: { date.addingTimeInterval(60) })
        let snapshot = await reopened.timeline()
        let marked = try XCTUnwrap(snapshot.entries.first { $0.marker == marker.uuidString })
        XCTAssertEqual(marked.firstAt, date)
        XCTAssertEqual(marked.detail, "Stop didn't respond")
        XCTAssertFalse(snapshot.incomplete)
    }

    func testExpiredWindowAndClearRemoveBookmarksAndNotes() async throws {
        let location = try folder(), prefs = try defaults(), date = start, marker = UUID()
        var first: DeveloperLogStore? = DeveloperLogStore(folder: location, defaults: prefs, now: { date })
        try await first?.markProblem(id: marker, at: date)
        try await first?.addProblemNote("Old note", marker: marker)
        first = nil
        let later = date.addingTimeInterval(48 * 3600)
        let next = DeveloperLogStore(folder: location, defaults: prefs, now: { later })
        let snapshot = await next.timeline()
        XCTAssertFalse(snapshot.entries.contains { $0.marker == marker.uuidString })
        let expiredExport = try await next.export()
        XCTAssertFalse(String(decoding: expiredExport, as: UTF8.self).contains("Old note"))
        do { try await next.addProblemNote("too late", marker: marker); XCTFail("Expired marker accepted a note") }
        catch { XCTAssertTrue(error is ProblemMarkerError) }
        let newID = UUID()
        try await next.markProblem(id: newID, at: later)
        await next.clear()
        let cleared = await next.timeline()
        XCTAssertFalse(cleared.entries.contains { $0.marker != nil })
    }

    func testDisabledRecordingDoesNotPretendToSaveAMarker() async throws {
        let prefs = try defaults(), date = start
        prefs.set(false, forKey: DeveloperLogStore.enabledKey)
        let log = DeveloperLogStore(folder: try folder(), defaults: prefs, now: { date })
        do { try await log.markProblem(id: UUID(), at: date); XCTFail("Disabled recording accepted a bookmark") }
        catch { XCTAssertTrue(error is ProblemMarkerError) }
        let snapshot = await log.timeline()
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertFalse(snapshot.recording)
    }

    func testFullLogRejectsBookmarkAndShowsMissingEvents() async throws {
        let date = start
        let log = DeveloperLogStore(folder: try folder(), defaults: try defaults(), now: { date }, capacity: 4096)
        for _ in 0..<20 { log.record("large_event", ["message": String(repeating: "x", count: 1000)]) }
        do { try await log.markProblem(id: UUID(), at: date); XCTFail("Full log accepted a bookmark") }
        catch { XCTAssertTrue(error is ProblemMarkerError) }
        let snapshot = await log.timeline()
        XCTAssertTrue(snapshot.incomplete)
        XCTAssertFalse(snapshot.entries.contains { $0.marker != nil })
    }
}

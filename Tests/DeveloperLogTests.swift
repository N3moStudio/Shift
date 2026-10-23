import XCTest
@testable import SessionPresentation

final class DeveloperLogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(to date: Date) { lock.lock(); value = date; lock.unlock() }
    }

    func testWindowKeepsFirstDayAndResetsExactlyAt48Hours() {
        let window = DeveloperLogWindow(startedAt: start)
        XCTAssertFalse(window.needsReset(at: start.addingTimeInterval(24 * 3600)))
        XCTAssertFalse(window.needsReset(at: start.addingTimeInterval(48 * 3600 - 0.001)))
        XCTAssertTrue(window.needsReset(at: start.addingTimeInterval(48 * 3600)))
        XCTAssertTrue(window.needsReset(at: start.addingTimeInterval(7 * 24 * 3600)))
    }

    func testClockMovingBackwardsDoesNotKeepAnOldWindowForever() {
        XCTAssertTrue(DeveloperLogWindow(startedAt: start).needsReset(at: start.addingTimeInterval(-1)))
    }

    func testDetailsKeepCoordinatesButRejectCredentialKeysAndBoundText() {
        let entry = DeveloperLogEvent(process: "test", event: "location", details: [
            "latitude": "12.3456789", "longitude": "-23.456789", "token": "sensitive",
            "pairing_file": "sensitive", "PASSWORD": "sensitive", "message": String(repeating: "a", count: 5000)
        ])
        XCTAssertEqual(entry.details["latitude"], "12.3456789")
        XCTAssertEqual(entry.details["longitude"], "-23.456789")
        XCTAssertNil(entry.details["token"])
        XCTAssertNil(entry.details["pairing_file"])
        XCTAssertNil(entry.details["PASSWORD"])
        XCTAssertEqual(entry.details["message"]?.count, 1200)
    }

    func testOverlongKeysCannotCollideAndCrashTheRecorder() {
        let prefix = String(repeating: "a", count: 80)
        let entry = DeveloperLogEvent(process: "test", event: "test", details: [prefix + "x": "1", prefix + "y": "2"])
        XCTAssertTrue(entry.details.isEmpty)
    }

    func testDefiniteConnectionFailureDoesNotOfferStopForANewSession() {
        XCTAssertFalse(SessionFailureRules.needsClear(previousLocationMayRemain: false, failedBeforeWrite: true))
    }

    func testOldLocationAndUncertainWritesAlwaysKeepCleanupAvailable() {
        XCTAssertTrue(SessionFailureRules.needsClear(previousLocationMayRemain: true, failedBeforeWrite: true))
        XCTAssertTrue(SessionFailureRules.needsClear(previousLocationMayRemain: true, failedBeforeWrite: false))
        XCTAssertTrue(SessionFailureRules.needsClear(previousLocationMayRemain: false, failedBeforeWrite: false))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-log-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func preferences(recording: Bool = true) throws -> UserDefaults {
        let name = "Shift-log-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        if recording { defaults.set(true, forKey: DeveloperLogStore.enabledKey) }
        return defaults
    }
    func testDetailedRecordingRequiresOptInOnFreshInstall() throws {
        let log = DeveloperLogStore(folder: try temporaryFolder(), defaults: try preferences(recording: false))
        XCTAssertFalse(log.enabled)
        log.setEnabled(true)
        XCTAssertTrue(log.enabled)
    }
    private func entries(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 0x0A).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }

    func testRoutineWritesAreBatchedButFailureFlushesThemInOrder() async throws {
        let folder = try temporaryFolder(), date = start
        let log = DeveloperLogStore(folder: folder, defaults: try preferences(), now: { date })
        log.record("location_write_requested", ["id": "buffered-one"])
        log.record("location_write_result", ["id": "buffered-one", "result": "accepted"])
        _ = await log.summary(flush: false)
        let file = folder.appendingPathComponent("events.jsonl")
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("buffered-one"))
        log.record("location_write_result", ["id": "failure-two", "result": "failed"])
        _ = await log.summary(flush: false)
        let rows = try entries(Data(contentsOf: file)).filter { ($0["event"] as? String)?.hasPrefix("location_write_") == true }
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, ["location_write_requested", "location_write_result", "location_write_result"])
        XCTAssertEqual((rows.last?["details"] as? [String: String])?["result"], "failed")
    }

    func testExportFlushesPendingRoutineRecords() async throws {
        let folder = try temporaryFolder(), date = start
        let log = DeveloperLogStore(folder: folder, defaults: try preferences(), now: { date })
        log.record("location_write_requested", ["id": "export-pending"])
        let text = String(decoding: try await log.export(), as: UTF8.self)
        XCTAssertTrue(text.contains("export-pending"))
    }

    func testScheduledBatchFlushesWithoutAnotherEvent() async throws {
        let folder = try temporaryFolder(), date = start
        let log = DeveloperLogStore(folder: folder, defaults: try preferences(), now: { date }, batchDelay: 0.01)
        log.record("location_write_requested", ["id": "scheduled-batch"])
        _ = await log.summary(flush: false)
        let file = folder.appendingPathComponent("events.jsonl")
        var written = false
        for _ in 0..<100 {
            written = String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("scheduled-batch")
            if written { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(written)
    }

    func testClearDiscardsPendingRecordsAndCancelledFlushCannotRestoreThem() async throws {
        let folder = try temporaryFolder(), date = start
        let log = DeveloperLogStore(folder: folder, defaults: try preferences(), now: { date }, batchDelay: 0.02)
        log.record("location_write_requested", ["id": "discard-this-batch"])
        await log.clear()
        log.record("location_write_requested", ["id": "keep-new-batch"])
        try await Task.sleep(nanoseconds: 50_000_000)
        let text = String(decoding: try await log.export(), as: UTF8.self)
        XCTAssertFalse(text.contains("discard-this-batch"))
        XCTAssertTrue(text.contains("keep-new-batch"))
    }

    func testPendingBytesCountTowardCapacityAndWindowExpiryDropsThem() async throws {
        let clock = Clock(start), folder = try temporaryFolder()
        let log = DeveloperLogStore(folder: folder, defaults: try preferences(), now: { clock.read() }, capacity: 8192)
        for index in 0..<30 { log.record("location_write_requested", ["id": "old-\(index)", "message": String(repeating: "x", count: 1000)]) }
        let summary = await log.summary()
        XCTAssertGreaterThan(summary.omitted, 0)
        XCTAssertLessThanOrEqual(summary.bytes, 8192)
        clock.advance(to: start.addingTimeInterval(DeveloperLogWindow.duration + 1))
        log.record("location_write_requested", ["id": "new-window"])
        let text = String(decoding: try await log.export(), as: UTF8.self)
        XCTAssertFalse(text.contains("old-"))
        XCTAssertTrue(text.contains("new-window"))
    }

    func testWindowExpiryDiscardsUnwrittenRoutineRecords() async throws {
        let clock = Clock(start), folder = try temporaryFolder()
        let log = DeveloperLogStore(folder: folder, defaults: try preferences(), now: { clock.read() })
        log.record("location_write_requested", ["id": "expired-unwritten"])
        _ = await log.summary(flush: false)
        clock.advance(to: start.addingTimeInterval(DeveloperLogWindow.duration + 1))
        let text = String(decoding: try await log.export(), as: UTF8.self)
        XCTAssertFalse(text.contains("expired-unwritten"))
    }

    func testExportRetainsWindowAcrossRelaunchBeforeExpiry() async throws {
        let folder = try temporaryFolder(), defaults = try preferences(), date = start
        var first: DeveloperLogStore? = DeveloperLogStore(folder: folder, defaults: defaults, now: { date })
        first?.record("first_location", ["latitude": "1", "longitude": "2"])
        _ = await first?.summary() // Wait for queued disk writes.
        first = nil
        let next = DeveloperLogStore(folder: folder, defaults: defaults, now: { date.addingTimeInterval(36 * 3600) })
        let output = try entries(await next.export())
        XCTAssertTrue(output.contains { $0["event"] as? String == "first_location" })
        let summary = await next.summary()
        XCTAssertEqual(summary.start, date)
        XCTAssertFalse(summary.storageError)
    }

    func testExpiredDataIsDeletedBeforeExportAfterLongClosure() async throws {
        let folder = try temporaryFolder(), defaults = try preferences(), date = start
        var first: DeveloperLogStore? = DeveloperLogStore(folder: folder, defaults: defaults, now: { date })
        first?.record("expired_location", ["latitude": "1.2345"])
        _ = await first?.summary()
        first = nil
        let later = date.addingTimeInterval(5 * 24 * 3600)
        let next = DeveloperLogStore(folder: folder, defaults: defaults, now: { later })
        let data = try await next.export()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("expired_location"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: folder.appendingPathComponent("events.jsonl")), as: UTF8.self).contains("1.2345"))
        let summary = await next.summary()
        XCTAssertEqual(summary.start, date.addingTimeInterval(4 * 24 * 3600))
    }

    func testClearStartsNewBatchAndDisabledRecordingOmitsLocations() async throws {
        let folder = try temporaryFolder(), defaults = try preferences(), date = start
        let log = DeveloperLogStore(folder: folder, defaults: defaults, now: { date })
        log.record("before_clear")
        await log.clear()
        log.setEnabled(false)
        log.record("disabled_location", ["latitude": "4.5678"])
        let text = String(decoding: try await log.export(), as: UTF8.self)
        XCTAssertFalse(text.contains("before_clear"))
        XCTAssertFalse(text.contains("disabled_location"))
        XCTAssertTrue(text.contains("recording_changed"))
    }

    func testCapacitySurvivesRelaunchWithoutCorruptingJSON() async throws {
        let folder = try temporaryFolder(), defaults = try preferences(), date = start
        var log: DeveloperLogStore? = DeveloperLogStore(folder: folder, defaults: defaults, now: { date }, capacity: 8192)
        for _ in 0..<30 { log?.record("large_event", ["message": String(repeating: "x", count: 1000)]) }
        let before = await log?.summary()
        XCTAssertGreaterThan(before?.omitted ?? 0, 0)
        XCTAssertLessThanOrEqual(before?.bytes ?? 0, 8192)
        log = nil
        let reopened = DeveloperLogStore(folder: folder, defaults: defaults, now: { date }, capacity: 8192)
        reopened.record("must_be_omitted")
        let output = try entries(await reopened.export())
        XCTAssertTrue(output.contains { $0["event"] as? String == "log_capacity_reached" })
        XCTAssertFalse(output.contains { $0["event"] as? String == "must_be_omitted" })
        let summary = await reopened.summary()
        XCTAssertGreaterThan(summary.omitted, 0)
    }

    func testFirstEventAtLiveWindowBoundaryIsRetainedAndOldBatchRemoved() async throws {
        let clock = Clock(start), folder = try temporaryFolder(), defaults = try preferences()
        let log = DeveloperLogStore(folder: folder, defaults: defaults, now: { clock.read() })
        log.record("old_batch")
        _ = await log.summary()
        clock.advance(to: start.addingTimeInterval(DeveloperLogWindow.duration + 0.2))
        log.record("first_new_event")
        let text = String(decoding: try await log.export(), as: UTF8.self)
        XCTAssertFalse(text.contains("old_batch"))
        XCTAssertTrue(text.contains("first_new_event"))
    }

    func testInterruptedFinalLineIsRemovedBeforeRelaunchAppends() async throws {
        let date = start, folder = try temporaryFolder(), defaults = try preferences()
        var log: DeveloperLogStore? = DeveloperLogStore(folder: folder, defaults: defaults, now: { date })
        log?.record("complete_record")
        _ = await log?.summary()
        log = nil
        let file = try FileHandle(forWritingTo: folder.appendingPathComponent("events.jsonl"))
        try file.seekToEnd()
        try file.write(contentsOf: Data("{\"unfinished".utf8))
        try file.close()
        let reopened = DeveloperLogStore(folder: folder, defaults: defaults, now: { date.addingTimeInterval(60) })
        reopened.record("after_restart")
        let output = try entries(await reopened.export())
        XCTAssertTrue(output.contains { $0["event"] as? String == "complete_record" })
        XCTAssertTrue(output.contains { $0["event"] as? String == "after_restart" })
    }

    func testCorruptedWindowMetadataCannotExtendRetentionOfOldLocations() async throws {
        let date = start, folder = try temporaryFolder(), defaults = try preferences()
        try Data("bad metadata".utf8).write(to: folder.appendingPathComponent("window.json"))
        try Data("old private data\n".utf8).write(to: folder.appendingPathComponent("events.jsonl"))
        let log = DeveloperLogStore(folder: folder, defaults: defaults, now: { date })
        let text = String(decoding: try await log.export(), as: UTF8.self)
        XCTAssertFalse(text.contains("old private data"))
        _ = try entries(Data(text.utf8))
    }
}

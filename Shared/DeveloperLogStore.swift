import Foundation

/// File I/O stays off the main thread and all changes use one serial queue.
/// This log is intentionally separate from the short, coordinate-free report.
final class DeveloperLogStore: @unchecked Sendable {
    static let shared = DeveloperLogStore()
    static let enabledKey = "locus.developerLogEnabled"
    static let maximumBytes = 256 * 1024 * 1024
    private let queue = DispatchQueue(label: "locus.developer-log", qos: .utility)
    private let process = UUID().uuidString
    private let folder: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let capacity: Int
    private let createdAt: Date
    private var window: DeveloperLogWindow?
    private var handle: FileHandle?
    private var byteCount = 0
    private var pendingData = Data()
    private var pendingFlush: DispatchWorkItem?
    private var flushGeneration = UUID()
    private let batchDelay: TimeInterval
    private let maximumBatchBytes = 32 * 1024
    private var omittedEvents = 0
    private var storageError = false
    private var capacityReached = false
    private var folderPrepared = false
    private var timelineArchive: SessionTimelineArchive?
    private var timelineDirty = false
    private var lastTimelineWrite = Date.distantPast
    private var timelineURL: URL { folder.appendingPathComponent("timeline.json") }
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()
    private var logURL: URL { folder.appendingPathComponent("events.jsonl") }
    private var metadataURL: URL { folder.appendingPathComponent("window.json") }
    private var capacityURL: URL { folder.appendingPathComponent("capacity.flag") }
    var enabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
    private var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    init(folder: URL? = nil, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         capacity: Int = DeveloperLogStore.maximumBytes, batchDelay: TimeInterval = 5) {
        self.defaults = defaults; self.now = now; self.capacity = max(4096, capacity); createdAt = now()
        self.batchDelay = batchDelay.isFinite ? min(5, max(0.01, batchDelay)) : 5
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeveloperLog", isDirectory: true)
        queue.async {
            do {
                try self.prepare(at: self.now())
                self.append(DeveloperLogEvent(time: self.now(), process: self.process, event: "process_started", details: [
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "prior_process": "A new process is running. Previous exit time and cause (force-close, crash, or system termination) are unknown."
                ]))
            } catch { self.storageError = true }
        }
    }

    func record(_ event: String, _ details: [String: String] = [:]) {
        guard enabled else { return }
        // Timestamp at the event, not later when its disk write runs.
        let entry = DeveloperLogEvent(time: now(), process: process, event: event, details: details)
        queue.async { self.append(entry) }
    }

    func maintenance(flush: Bool = false) {
        queue.async {
            do {
                try self.prepare(at: self.now())
                if flush { try self.flushPending(); try self.handle?.synchronize(); try self.persistTimeline() }
            } catch { self.storageError = true }
        }
    }

    func setEnabled(_ value: Bool) {
        record("recording_changed", ["enabled": String(value)])
        defaults.set(value, forKey: Self.enabledKey)
        if value { record("recording_resumed") }
        maintenance(flush: true)
    }

    func clear() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                do { try self.prepare(at: self.now()); try self.reset(at: self.now()) } catch { self.storageError = true }
                continuation.resume()
            }
        }
        record("log_cleared_by_user")
    }

    struct Summary: Sendable {
        let start: Date
        let end: Date
        let bytes: Int
        let omitted: Int
        let storageError: Bool
    }

    func summary(flush: Bool = true) async -> Summary {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try self.prepare(at: self.now())
                    if flush { try self.flushPending() }
                } catch { self.storageError = true }
                let value = self.window ?? DeveloperLogWindow(startedAt: self.now())
                continuation.resume(returning: Summary(start: value.startedAt, end: value.endsAt,
                    bytes: self.byteCount, omitted: max(self.omittedEvents, self.capacityReached ? 1 : 0), storageError: self.storageError))
            }
        }
    }

    struct TimelineSnapshot: Sendable {
        let entries: [SessionTimelineEntry]
        let start: Date
        let end: Date
        let trimmed: Bool
        let recording: Bool
        let incomplete: Bool
    }

    func timeline() async -> TimelineSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                do { try self.prepare(at: self.now()); try self.persistTimeline() }
                catch { self.storageError = true }
                let value = self.window ?? DeveloperLogWindow(startedAt: self.now())
                continuation.resume(returning: TimelineSnapshot(entries: self.timelineArchive?.entries ?? [],
                    start: value.startedAt, end: value.endsAt, trimmed: self.timelineArchive?.trimmed ?? false,
                    recording: self.enabled, incomplete: self.storageError || self.capacityReached))
            }
        }
    }

    /// Unlike fire-and-forget touch logging, explicit bookmarks acknowledge
    /// whether the complete record was written and flushed before UI success.
    func markProblem(id: UUID, at time: Date) async throws {
        try await saveMarkerEvent(DeveloperLogEvent(time: time, process: process, event: "problem_moment",
            details: ["marker": id.uuidString]))
    }

    func addProblemNote(_ note: String, marker: UUID) async throws {
        try await saveMarkerEvent(DeveloperLogEvent(time: now(), process: process, event: "problem_note",
            details: ["marker": marker.uuidString, "note": String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))]))
    }

    private func saveMarkerEvent(_ entry: DeveloperLogEvent) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.enabled else { throw ProblemMarkerError.disabled }
                    try self.prepare(at: self.now())
                    if entry.event == "problem_note" {
                        guard self.timelineArchive?.entries.contains(where: { $0.marker == entry.details["marker"] }) == true else {
                            throw ProblemMarkerError.expired
                        }
                    }
                    guard self.append(entry) else { throw ProblemMarkerError.unavailable }
                    try self.flushPending()
                    try self.handle?.synchronize()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func export() async throws -> Data {
        record("developer_log_export_requested")
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.prepare(at: self.now())
                    try self.flushPending()
                    try self.handle?.synchronize()
                    let header = DeveloperLogEvent(time: self.now(), process: self.process, event: "export_information", details: [
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                        "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                        "format": "Locus developer log v1, one JSON object per line; UTC time, Unix timeMilliseconds and monotonic uptime",
                        "window_start": self.window?.startedAt.ISO8601Format() ?? "unknown",
                        "window_end": self.window?.endsAt.ISO8601Format() ?? "unknown",
                        "privacy": "Includes exact locations sent by Shift and optional problem notes you enter. No automatic keyboard capture, credentials, pairing file, or automatic upload.",
                        "limits": "App-observed events only. Routine events may be buffered for up to 5 seconds while running and can be lost on abrupt termination. iOS does not expose an Airplane Mode toggle or reliable force-close callback. Network state is not proof of a working developer connection. Requests to show alerts/notifications are not proof they were seen. Suspended/terminated time has gaps; cleanup runs when Shift can run again.",
                        "storage_error_observed": String(self.storageError),
                        "omitted_this_process": String(self.omittedEvents),
                        "capacity_reached": String(self.capacityReached),
                        "capacity": "256 MiB per window. At capacity, additional events are omitted until reset. Check log_capacity_reached."
                    ])
                    var data = try self.encoder.encode(header)
                    data.append(0x0A)
                    if FileManager.default.fileExists(atPath: self.logURL.path) { data.append(try Data(contentsOf: self.logURL)) }
                    continuation.resume(returning: data)
                } catch { self.storageError = true; continuation.resume(throwing: error) }
            }
        }
    }

    private func prepare(at now: Date) throws {
        let files = FileManager.default
        if !folderPrepared {
        #if os(iOS)
        try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var protectedFolder = folder; try protectedFolder.setResourceValues(resource)
            folderPrepared = true
        }
        if window == nil, let data = try? Data(contentsOf: metadataURL) {
            window = try? decoder.decode(DeveloperLogWindow.self, from: data)
        }
        if let window {
            if window.needsReset(at: now) { try reset(at: window.currentBatchStart(at: now)) }
        } else {
            try reset(at: DeveloperLogWindow(startedAt: createdAt).currentBatchStart(at: now))
        }
        if timelineArchive == nil, let window {
            if let size = try? files.attributesOfItem(atPath: timelineURL.path)[.size] as? Int,
               size <= 2 * 1024 * 1024,
               let data = try? Data(contentsOf: timelineURL),
               let archive = try? decoder.decode(SessionTimelineArchive.self, from: data),
               archive.isValid, abs(archive.windowStart.timeIntervalSince(window.startedAt)) < 1 {
                timelineArchive = archive
            } else {
                // A missing index is normal on upgrade. A damaged existing
                // index must not silently imply that the timeline is complete.
                if files.fileExists(atPath: timelineURL.path) { storageError = true }
                timelineArchive = SessionTimelineArchive(windowStart: window.startedAt)
            }
        }
        if handle == nil {
            if !files.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL, options: writeOptions)
            }
            handle = try FileHandle(forWritingTo: logURL)
            byteCount = Int(try handle?.seekToEnd() ?? 0)
            // A killed process can leave an incomplete final record. Keep all
            // complete lines and remove only that tail before the next append.
            if byteCount > 0 {
                let reader = try FileHandle(forReadingFrom: logURL)
                defer { try? reader.close() }
                let offset = max(0, byteCount - 256 * 1024)
                try reader.seek(toOffset: UInt64(offset))
                let tail = try reader.readToEnd() ?? Data()
                if tail.last != 0x0A {
                    let validEnd = tail.lastIndex(of: 0x0A).map { offset + $0 + 1 } ?? 0
                    try handle?.truncate(atOffset: UInt64(validEnd))
                    try handle?.seek(toOffset: UInt64(validEnd))
                    byteCount = validEnd
                }
            }
            capacityReached = files.fileExists(atPath: capacityURL.path)
        }
    }

    private func reset(at now: Date) throws {
        cancelPendingFlush()
        pendingData.removeAll(keepingCapacity: true)
        try handle?.close(); handle = nil
        // Truncate before writing the new window, so a crash cannot attach old
        // records to a fresh expiry date.
        try Data().write(to: logURL, options: writeOptions)
        timelineArchive = nil; timelineDirty = false
        if FileManager.default.fileExists(atPath: timelineURL.path) { try FileManager.default.removeItem(at: timelineURL) }
        if FileManager.default.fileExists(atPath: capacityURL.path) { try FileManager.default.removeItem(at: capacityURL) }
        let value = DeveloperLogWindow(startedAt: now)
        try encoder.encode(value).write(to: metadataURL, options: writeOptions)
        timelineArchive = SessionTimelineArchive(windowStart: now)
        lastTimelineWrite = .distantPast
        window = value; byteCount = 0; omittedEvents = 0; storageError = false; capacityReached = false
    }

    @discardableResult
    private func append(_ entry: DeveloperLogEvent) -> Bool {
        guard enabled || entry.event == "recording_changed" else { return false }
        do {
            try prepare(at: now())
            guard entry.time >= (window?.startedAt ?? .distantPast) else { return false }
            if capacityReached || byteCount + pendingData.count >= capacity { omittedEvents += 1; return false }
            var data = try encoder.encode(entry); data.append(0x0A)
            if byteCount + pendingData.count + data.count >= capacity - 2048 {
                try flushPending()
                if omittedEvents == 0 {
                    let event = DeveloperLogEvent(time: now(), process: process, event: "log_capacity_reached")
                    var marker = try encoder.encode(event)
                    marker.append(0x0A); try handle?.write(contentsOf: marker); byteCount += marker.count
                    updateTimeline(event)
                }
                omittedEvents += 1
                // Keep the stop condition across process restarts without
                // padding the JSONL file with invalid zero bytes.
                try Data().write(to: capacityURL, options: writeOptions)
                capacityReached = true
                return false
            }
            pendingData.append(data)
            if !entry.canBatch || pendingData.count >= maximumBatchBytes {
                try flushPending()
            } else { scheduleFlush() }
            updateTimeline(entry)
            return true
        } catch { storageError = true; return false }
    }

    private func cancelPendingFlush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        flushGeneration = UUID()
    }

    private func scheduleFlush() {
        guard pendingFlush == nil else { return }
        let generation = flushGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.flushGeneration else { return }
            do {
                // Enforce retention even if iOS delayed this callback.
                try self.prepare(at: self.now())
                try self.flushPending()
            } catch { self.storageError = true; self.cancelPendingFlush() }
        }
        pendingFlush = work
        queue.asyncAfter(deadline: .now() + batchDelay, execute: work)
    }

    private func flushPending() throws {
        cancelPendingFlush()
        guard !pendingData.isEmpty else { return }
        do {
            try handle?.write(contentsOf: pendingData)
            byteCount += pendingData.count
            pendingData.removeAll(keepingCapacity: true)
        } catch {
            // A failed write may have left a partial tail. Reopen through
            // prepare's existing repair path before accepting new records.
            pendingData.removeAll(keepingCapacity: true)
            try? handle?.close(); handle = nil
            throw error
        }
    }

    private func updateTimeline(_ event: DeveloperLogEvent) {
        guard timelineArchive?.include(event) == true else { return }
        timelineDirty = true
        if event.event != "location_write_result" || event.details["result"] != "accepted" ||
           now().timeIntervalSince(lastTimelineWrite) >= 30 {
            do { try persistTimeline() } catch { storageError = true }
        }
    }

    private func persistTimeline() throws {
        guard timelineDirty, let timelineArchive else { return }
        // An index must never describe routine records still only in memory.
        try flushPending()
        try encoder.encode(timelineArchive).write(to: timelineURL, options: writeOptions)
        timelineDirty = false; lastTimelineWrite = now()
    }
}

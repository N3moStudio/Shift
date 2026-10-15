import Foundation

struct SessionTimelineEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let kind: String
    let firstAt: Date
    var lastAt: Date
    let title: String
    var detail: String
    var count = 1
    var marker: String?
}

/// A small index of important log events, never the full touch/location stream.
struct SessionTimelineArchive: Codable, Sendable {
    static let limit = 1000
    let windowStart: Date
    var entries: [SessionTimelineEntry] = []
    var trimmed = false

    var isValid: Bool {
        windowStart.timeIntervalSince1970.isFinite && entries.count <= Self.limit &&
        Set(entries.map(\.id)).count == entries.count && entries.allSatisfy {
            $0.firstAt >= windowStart && $0.lastAt >= $0.firstAt &&
            $0.lastAt.timeIntervalSince1970.isFinite && $0.lastAt < windowStart.addingTimeInterval(DeveloperLogWindow.duration) && $0.count > 0 &&
            $0.title.count <= 200 && $0.detail.count <= 300
        }
    }

    @discardableResult
    mutating func include(_ event: DeveloperLogEvent) -> Bool {
        guard event.time >= windowStart, event.time < windowStart.addingTimeInterval(DeveloperLogWindow.duration) else { return false }
        let d = event.details
        if event.event == "problem_note", let marker = d["marker"],
           let index = entries.firstIndex(where: { $0.marker == marker }) {
            entries[index].detail = String((d["note"] ?? "").prefix(300))
            return true
        }
        let title: String
        var detail = ""
        var kind = event.event
        switch event.event {
        case "process_started":
            title = "Shift started a new process"
            detail = "The previous exit time and cause are unknown."
        case "scene_changed":
            if d["phase"] == "active" { title = "Shift is on screen" }
            else if d["phase"] == "background" { title = "Shift moved to the background" }
            else { return false }
        case "network_path_changed":
            if d["monitor"] == "wifi" {
                title = d["status"] == "satisfied" ? "Wi-Fi path available" : "Wi-Fi path unavailable"
            } else {
                title = d["status"] == "satisfied" ? "Network path available" : "Network path unavailable"
            }
            detail = "Network observation only; it doesn't tell us whether location commands work."
        case "location_write_result":
            guard d["result"] == "accepted" || d["result"] == "failed" else { return false }
            kind += "_" + (d["result"] ?? "")
            title = d["result"] == "accepted" ? "Location update accepted" : "Location update failed"
            detail = d["result"] == "accepted" ? "The iPhone accepted the command. Other apps haven't been checked."
                : "Shift couldn't confirm this update. An earlier location may still remain."
        case "clear_result":
            title = d["result"] == "accepted" ? "Stop command accepted" : "Stop couldn't be confirmed"
            detail = d["result"] == "accepted" ? "The iPhone accepted the request to clear the simulated location."
                : "The earlier simulated location may still remain."
        case "route_state_changed":
            switch d["state"] {
            case "moving": title = "Route moving"
            case "paused": title = "Route paused"
            case "waiting": title = "Waiting at a route stop"
            case "arrived", "completed": title = "Route arrived"
            case "interrupted": title = "Route interrupted"
            case "none": title = "No route running"
            default: return false
            }
        case "user_reported_test_event":
            title = "Test event you marked"
            detail = d["description"] ?? ""
        case "problem_moment":
            title = "Something went wrong"
            detail = "Moment marked for the developer log."
        case "saved_trip_version_restored": title = "Earlier saved-trip version restored"
        case "recording_changed": title = d["enabled"] == "false" ? "Recording turned off" : "Recording turned on"
        case "recording_resumed": title = "Recording resumed"
        case "log_cleared_by_user": title = "Developer log cleared"
        case "log_capacity_reached": title = "Developer log reached its storage limit"
        default: return false
        }
        // Route updates can arrive several times a second. Keep their latest
        // acceptance time without burying failures or marking them as verified.
        if kind == "location_write_result_accepted", var last = entries.last,
           last.kind == kind, event.time >= last.lastAt,
           event.time.timeIntervalSince(last.firstAt) <= 300 {
            last.count += 1; last.lastAt = event.time
            entries[entries.count - 1] = last
        } else {
            entries.append(SessionTimelineEntry(kind: kind, firstAt: event.time, lastAt: event.time,
                title: title, detail: String(detail.prefix(300)), marker: d["marker"]))
        }
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit); trimmed = true
        }
        return true
    }
}

enum ProblemMarkerError: LocalizedError {
    case disabled, unavailable, expired
    var errorDescription: String? {
        switch self {
        case .disabled: return "Developer log recording is off. Turn it on in Settings → Export or import, then mark a new moment."
        case .unavailable: return "This moment couldn't be saved. The developer log may be full or storage may be unavailable. Export or clear it in Settings → Export or import."
        case .expired: return "This moment is no longer available for notes. Mark a new moment to add one."
        }
    }
}

import Foundation

/// Reports accept fixed categories, never raw engine errors, places, coordinates,
/// pairing files, network addresses, device names, or saved-route descriptions.
enum DiagnosticEventKind: Equatable {
    case opened, foreground, background, pairingAvailable, pairingMissing
    case phase(SessionPhase), route(JourneyState?), joystick(Bool), lowPower(Bool)
    case firstCommandSucceeded, commandsSucceeded, recordingResumed

    var text: String {
        switch self {
        case .opened: return "Shift opened"
        case .foreground: return "App became active"
        case .background: return "App entered background"
        case .pairingAvailable: return "Pairing file available"
        case .pairingMissing: return "Pairing file missing"
        case .phase(let phase): return "Connection: \(phase.rawValue)"
        case .route(let state): return "Route: \(state?.rawValue ?? "none")"
        case .joystick(let enabled): return "Joystick: \(enabled ? "on" : "off")"
        case .lowPower(let enabled): return "Low Power Mode: \(enabled ? "on" : "off")"
        case .firstCommandSucceeded: return "First location command succeeded"
        case .commandsSucceeded: return "More location commands succeeded"
        case .recordingResumed: return "Troubleshooting events enabled"
        }
    }
}

struct DiagnosticEvent: Equatable {
    let elapsedSeconds: Int
    let kind: DiagnosticEventKind
}

struct DiagnosticBuffer {
    static let capacity = 100
    private(set) var events: [DiagnosticEvent] = []
    private(set) var successfulCommands = 0
    private(set) var updateFailures = 0
    private(set) var startedUptime: TimeInterval
    private(set) var lastSuccessUptime: TimeInterval?
    private var lastSuccessEventUptime: TimeInterval?

    init(uptime: TimeInterval) { startedUptime = uptime }

    mutating func record(_ kind: DiagnosticEventKind, uptime: TimeInterval) {
        guard uptime.isFinite, startedUptime.isFinite else { return }
        let elapsed = min(31_536_000, max(0, uptime - startedUptime))
        events.append(DiagnosticEvent(elapsedSeconds: Int(elapsed), kind: kind))
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
        if kind == .phase(.disconnected) { updateFailures += 1 }
    }

    mutating func commandSucceeded(uptime: TimeInterval) {
        guard uptime.isFinite else { return }
        successfulCommands += 1
        lastSuccessUptime = uptime
        // Keep failures and UI state changes visible instead of flooding the
        // bounded report with every 0.5-second route movement.
        if lastSuccessEventUptime == nil || uptime - (lastSuccessEventUptime ?? uptime) >= 30 {
            record(successfulCommands == 1 ? .firstCommandSucceeded : .commandsSucceeded, uptime: uptime)
            lastSuccessEventUptime = uptime
        }
    }

    func lastSuccessAge(uptime: TimeInterval) -> Int? {
        guard let lastSuccessUptime, uptime.isFinite, uptime >= lastSuccessUptime else { return nil }
        return Int(min(31_536_000, uptime - lastSuccessUptime))
    }

    mutating func clear(uptime: TimeInterval) { self = DiagnosticBuffer(uptime: uptime) }
}

enum ProblemCategory: String, CaseIterable, Identifiable {
    case button = "Button or gesture", route = "Route or speed", connection = "Connection"
    case display = "Live Activity or appearance", privacy = "Privacy controls", setup = "Setup", other = "Something else"
    var id: String { rawValue }
}

enum DiagnosticSetting: String, CaseIterable {
    case lowPower = "Low Power Mode", smooth = "Smooth movement", glass = "Glass panel"
    case liveActivity = "Live Activities", hideLockName = "Hide Lock Screen name", hideIslandName = "Hide Island name"
    case pairing = "Pairing file available", tunnel = "Tunnel interface hint (not a connection test)", joystick = "Joystick active"
    case recording = "Troubleshooting events enabled"
    case appLock = "App authentication enabled", switcherCover = "Hide app-switcher preview", saveRecents = "Save recent locations"
}

struct ProblemReportContext {
    var version: String
    var build: String
    var systemVersion: String
    var isTablet: Bool
    var phase: SessionPhase
    var routeState: JourneyState?
    var settings: [DiagnosticSetting: Bool]
    var historyRetention: RecentHistoryRetention? = nil
}

enum PrivateProblemReport {
    /// Versions are the only external strings in automatic diagnostics. Reject
    /// unexpected text rather than trying to redact secrets out of an error log.
    static func versionNumber(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 24,
              value.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) || $0.value == 46 }),
              value.unicodeScalars.contains(where: { (48...57).contains(Int($0.value)) }) else { return "unknown" }
        return value
    }

    static func render(context: ProblemReportContext, buffer: DiagnosticBuffer,
                       category: ProblemCategory, uptime: TimeInterval,
                       includeNotes: Bool = false, notes: String = "") -> String {
        var lines = [
            "SHIFT PROBLEM REPORT",
            "Category: \(category.rawValue)",
            "App: \(versionNumber(context.version)) (\(versionNumber(context.build)))",
            "iOS: \(versionNumber(context.systemVersion))",
            "Device family: \(context.isTablet ? "iPad" : "iPhone / other iOS device")",
            "Connection evidence: \(context.phase.rawValue)",
            "Route state: \(context.routeState?.rawValue ?? "none")",
            "Successful location commands observed: \(buffer.successfulCommands)",
            "Disconnected status events observed: \(buffer.updateFailures)",
            "Last observed success: \(buffer.lastSuccessAge(uptime: uptime).map { "\($0) seconds ago" } ?? "none recorded")",
            "", "SETTINGS"
        ]
        for setting in DiagnosticSetting.allCases {
            if let enabled = context.settings[setting] { lines.append("\(setting.rawValue): \(enabled ? "on" : "off")") }
        }
        if let retention = context.historyRetention { lines.append("Recent-location retention: \(retention.title)") }
        lines += ["", "RECENT EVENTS (elapsed time since this in-memory report began)"]
        if buffer.events.isEmpty { lines.append("No events recorded.") }
        for event in buffer.events { lines.append("+\(event.elapsedSeconds)s  \(event.kind.text)") }
        lines += ["", "Automatic details exclude coordinates, place names, routes, pairing data, network addresses, and device identifiers.",
                  "Connection evidence does not verify what another app displays. Counts cover only this app process while event recording was enabled."]
        if includeNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["", "NOTES ADDED BY YOU (included exactly as entered, up to 2,000 characters)", String(notes.prefix(2_000))]
        }
        return lines.joined(separator: "\n")
    }
}

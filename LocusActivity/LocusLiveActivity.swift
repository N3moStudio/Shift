import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LocusActivityBundle: WidgetBundle {
    var body: some Widget { LocusLiveActivity(); LocusFavoriteWidget(); LocusLibraryWidget() }
}

struct LocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LocusActivityAttributes.self) { context in
            ActivityLockScreen(context: context)
                .activityBackgroundTint(ShiftPalette.color(.canvas, style: ShiftVisualStyle(storedValue: context.state.visualStyle), dark: true))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "shift://session"))
        } dynamicIsland: { context in
            let phase = context.state.presentedPhase(at: Date(), systemIsStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ShiftWidgetBrand(design: ShiftIconDesign(rawValue: context.state.iconDesign ?? "")).foregroundStyle(phase.tint(style: ShiftVisualStyle(storedValue: context.state.visualStyle)))
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let last = context.state.lastConfirmedAt, context.state.islandShowsTimer != false {
                        Text(last, style: .timer)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityLabel("Time since the last location update was sent")
                            .padding(.trailing, 6)
                    } else {
                        Image(systemName: phase.symbol).foregroundStyle(phase.tint(style: ShiftVisualStyle(storedValue: context.state.visualStyle)))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityDetails(state: context.state, phase: phase, place: context.state.islandPlace,
                                    journey: context.state.visibleJourney(onIsland: true, at: Date(), systemIsStale: context.isStale),
                                    showCommandTime: false,
                                    systemIsStale: context.isStale, compactServiceRows: true)
                        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 6)
                }
            } compactLeading: {
                Image(systemName: phase.symbol).foregroundStyle(phase.tint(style: ShiftVisualStyle(storedValue: context.state.visualStyle)))
            } compactTrailing: {
                // A system-rendered timer reports the age of a historical fact,
                // even when iOS delays host updates or the stale presentation.
                if context.state.remoteFindMy != nil || context.state.remoteLife360 != nil {
                    ServiceActivityIcons(state: context.state, systemIsStale: context.isStale)
                } else if let last = context.state.lastConfirmedAt, context.state.islandShowsTimer != false,
                   phase == .active || phase == .unverified {
                    Text(last, style: .timer).monospacedDigit()
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 48)
                        .accessibilityLabel("Time since last update; this is not a connection check")
                } else {
                    Image(systemName: phase.symbol).font(.caption2).foregroundStyle(phase.tint(style: ShiftVisualStyle(storedValue: context.state.visualStyle)))
                }
            } minimal: {
                if context.state.remoteFindMy != nil || context.state.remoteLife360 != nil {
                    ServiceActivityIcons(state: context.state, systemIsStale: context.isStale)
                } else {
                    Image(systemName: phase.symbol).foregroundStyle(phase.tint(style: ShiftVisualStyle(storedValue: context.state.visualStyle)))
                }
            }
            .widgetURL(URL(string: "shift://session"))
            .keylineTint(phase.tint(style: ShiftVisualStyle(storedValue: context.state.visualStyle)))
        }
    }
}

private struct ActivityLockScreen: View {
    let context: ActivityViewContext<LocusActivityAttributes>
    var body: some View {
        let phase = context.state.presentedPhase(at: Date(), systemIsStale: context.isStale)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ShiftWidgetBrand(design: ShiftIconDesign(rawValue: context.state.iconDesign ?? "")).foregroundStyle(phase.tint(style: ShiftVisualStyle(storedValue: context.state.visualStyle)))
                Image(systemName: phase.symbol).font(.caption).foregroundStyle(phase.tint(style: ShiftVisualStyle(storedValue: context.state.visualStyle)))
                Spacer()
                if context.state.lowPower {
                    Image(systemName: "battery.25percent").foregroundStyle(.yellow)
                        .accessibilityLabel("Low Power Mode")
                }
                if let last = context.state.lastConfirmedAt {
                    Text(last, style: .timer)
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("Time since the last location update was sent")
                }
            }
            ActivityDetails(state: context.state, phase: phase, place: context.state.place,
                            journey: context.state.visibleJourney(onIsland: false, at: Date(), systemIsStale: context.isStale),
                            systemIsStale: context.isStale)
        }
        .padding(18)
        .foregroundStyle(.white)
    }
}

private struct ActivityDetails: View {
    let state: SessionSnapshot
    let phase: SessionPhase
    let place: String?
    let journey: JourneyActivity?
    var showCommandTime = true
    var systemIsStale = false
    var compactServiceRows = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(phase.title).font(.headline).foregroundStyle(phase.tint(style: ShiftVisualStyle(storedValue: state.visualStyle)))
            if let remote = state.remoteFindMy {
                FindMyActivityStatus(remote: remote, systemIsStale: systemIsStale, inlineAge: compactServiceRows)
            }
            if let remote = state.remoteLife360 {
                FindMyActivityStatus(remote: remote, systemIsStale: systemIsStale, life360: true, inlineAge: compactServiceRows)
            }
            if state.remoteFindMy == nil && state.remoteLife360 == nil && phase == .active {
                Text("Check other apps separately.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let journey {
                HStack {
                    Text(journey.state.title)
                    Spacer()
                    if let arrival = journey.estimatedArrival, journey.state == .moving {
                        Text("ETA")
                        Text(arrival, style: .time)
                    }
                }
                .font(.caption)
                ProgressView(value: journey.progress).tint(phase.tint(style: ShiftVisualStyle(storedValue: state.visualStyle)))
                if journey.state != .arrived {
                    Text("\(JourneyText.distance(journey.remainingMetres)) remaining").font(.caption2)
                }
            }
            if phase == .unverified {
                Text("Open Shift to check. Simulation may still remain.").font(.caption)
            } else if phase == .disconnected {
                Text("Update failed; the old location may remain. Open Shift.").font(.caption)
            } else if let place {
                Text(place).font(.caption).lineLimit(1).privacySensitive()
            } else if phase != .active {
                Text(state.explanation).font(.caption)
            }
            if let last = state.lastConfirmedAt, showCommandTime {
                HStack(spacing: 4) {
                    Text("Command sent")
                    Text(last, style: .relative)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ServiceActivityIcons: View {
    let state: SessionSnapshot
    let systemIsStale: Bool
    var body: some View {
        HStack(spacing: 3) {
            if let remote = state.remoteFindMy {
                FindMyActivityStatus(remote: remote, systemIsStale: systemIsStale, compact: true)
            }
            if let remote = state.remoteLife360 {
                FindMyActivityStatus(remote: remote, systemIsStale: systemIsStale, compact: true, life360: true)
            }
        }.font(.caption2).accessibilityElement(children: .combine)
    }
}

private struct FindMyActivityStatus: View {
    let remote: RemoteFindMyActivity
    var systemIsStale = false
    var compact = false
    var life360 = false
    var inlineAge = false
    private var status: RemoteFindMyState { remote.presented(at: Date(), systemIsStale: systemIsStale) }
    private var tint: Color {
        switch status {
        case .match: return .green
        case .different: return .red
        case .ready, .off, .paused: return .secondary
        default: return .orange
        }
    }
    private var symbol: String {
        if life360 {
            switch status {
            case .match: return "person.crop.circle.badge.checkmark"
            case .different, .old, .blocked: return "person.crop.circle.badge.exclamationmark"
            default: return "person.crop.circle.badge.questionmark"
            }
        }
        switch status {
        case .match: return "checkmark.icloud"
        case .different: return "exclamationmark.icloud"
        case .old: return "clock.badge.exclamationmark"
        case .signIn, .pairing: return "lock.icloud"
        default: return "icloud"
        }
    }
    private var shortStatus: String {
        switch status {
        case .match: return "matched"
        case .different: return "differed"
        case .old: return "old report"
        case .signIn: return "sign in"
        case .blocked: return "blocked"
        case .unavailable: return "no recent check"
        case .waiting: return "waiting"
        case .ready: return "ready"
        case .paused: return "paused"
        case .pairing: return "reconnect"
        case .off: return "off"
        }
    }
    var body: some View {
        if compact {
            Image(systemName: symbol).foregroundStyle(tint)
                .accessibilityLabel(remote.title(at: Date(), systemIsStale: systemIsStale, life360: life360))
        } else if inlineAge {
            HStack(spacing: 6) {
                Label("\(life360 ? "Life360" : "Find My"): \(shortStatus)", systemImage: symbol)
                    .foregroundStyle(tint)
                    .accessibilityLabel(remote.title(at: Date(), systemIsStale: systemIsStale, life360: life360))
                Spacer(minLength: 0)
                if let date = remote.reportedAt {
                    Text(date, style: .relative).foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Location report age: ") + Text(date, style: .relative))
                }
            }.font(.caption2)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(remote.title(at: Date(), systemIsStale: systemIsStale, life360: life360), systemImage: symbol)
                    .font(.caption).foregroundStyle(tint)
                if let date = remote.reportedAt {
                    HStack(spacing: 4) { Text(life360 ? "Life360 location age:" : "Apple location age:"); Text(date, style: .relative) }
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension SessionPhase {
    func tint(style: ShiftVisualStyle) -> Color {
        switch self {
        case .active: return ShiftPalette.color(.accent, style: style, dark: true)
        case .disconnected: return .red
        case .unverified, .connecting, .reconnecting, .stopping: return .orange
        case .idle: return .secondary
        }
    }
}

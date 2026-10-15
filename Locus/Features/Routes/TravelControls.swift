import SwiftUI

struct RouteModeMenu: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @State private var proposed: TravelMode?
    @State private var showRouteChoice = false
    @State private var showSectionOverride = false

    var body: some View {
        Menu {
            ForEach(TravelMode.allCases) { mode in
                Button {
                    guard mode != session.travelMode else { return }
                    if session.routeActive, session.travelMode.needsRouteChoice(changingTo: mode) {
                        proposed = mode
                        showRouteChoice = true
                    } else if session.routeSectionSettingsEnabled {
                        proposed = mode
                        showSectionOverride = true
                    } else {
                        session.changeTravelMode(mode, keepCurrentPath: !session.routeActive)
                    }
                } label: {
                    Label(mode.title, systemImage: mode == session.travelMode ? "checkmark" : mode.icon)
                }
            }
            if session.routeSectionSettingsEnabled {
                Divider()
                Button("Use \(session.travelMode.title.lowercased()) for the rest") {
                    proposed = session.travelMode
                    showSectionOverride = true
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: session.travelMode.icon)
                Text(session.travelMode.title)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .disabled(!session.canEditRouteMovement || (session.journey != nil && !session.isSpoofing))
        .accessibilityLabel("Change travel mode")
        .loggedConfirmationDialog("Replace remaining section settings?", isPresented: $showSectionOverride, titleVisibility: .visible) {
            if let proposed {
                Button("Use \(proposed.title.lowercased()) for the rest") {
                    session.changeTravelMode(proposed, keepCurrentPath: true)
                }
            }
            Button("Cancel", role: .cancel) { proposed = nil }
        } message: {
            Text("Keep this path and use one mode for the remaining route. Your saved trip is unchanged. Speed-only edits apply to the current section without replacing later sections.")
        }
        .loggedConfirmationDialog("Change to \(proposed?.title ?? "another mode")?", isPresented: $showRouteChoice, titleVisibility: .visible) {
            if let proposed {
                Button("Find a new \(proposed.title.lowercased()) route") { session.reroute(to: proposed, pairing: pairing) }
                Button("Keep this path, use \(proposed.title.lowercased()) speed") { session.changeTravelMode(proposed, keepCurrentPath: true) }
            }
            Button("Cancel", role: .cancel) { proposed = nil }
        } message: {
            Text("A different path is needed for matching directions. Find a new route from your current spoofed location, or explicitly keep this path and only change speed. Either choice replaces remaining section settings with the chosen mode.")
        }
    }
}

struct MovementSpeedControl: View {
    @EnvironmentObject private var session: SpoofSession
    private var mode: TravelMode { session.travelMode }
    private var value: Binding<Double> {
        Binding(get: { session.speedMPH(for: mode) }, set: { session.setSpeedMPH($0, for: mode) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Target speed", systemImage: "speedometer")
                Spacer()
                Text(String(format: "%.1f mph", session.speedMPH(for: mode))).monospacedDigit().bold()
            }
            .font(.subheadline)
            HStack(spacing: 8) {
                Button { session.setSpeedMPH(session.speedMPH(for: mode) - 1, for: mode) } label: {
                    Image(systemName: "minus.circle").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Decrease speed")
                Slider(value: value, in: mode.speedRangeMPH, step: mode == .walk || mode == .run ? 0.1 : 1)
                    .accessibilityLabel("\(mode.title) speed in miles per hour")
                Button { session.setSpeedMPH(session.speedMPH(for: mode) + 1, for: mode) } label: {
                    Image(systemName: "plus.circle").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Increase speed")
            }
            .buttonStyle(.borderless)
            HStack {
                Text(String(format: "%.0f–%.0f mph", mode.speedRangeMPH.lowerBound, mode.speedRangeMPH.upperBound))
                Spacer()
                Text(String(format: "%.1f km/h", session.speedMPH(for: mode) * 1.609344))
            }
            .font(.caption).foregroundStyle(.secondary)
            Button {
                session.resetToUsualSpeed(for: mode)
            } label: {
                Label(String(format: "Reset speed · %.1f mph", session.usualSpeedMPH(for: mode)), systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!session.canEditRouteMovement)
            Toggle("Smooth route movement", isOn: $session.smoothMovement)
                .font(.subheadline)
            if session.routeSectionSettingsEnabled {
                Text("Section settings are on. Speed changes apply to this section only. Choosing a different mode replaces the remaining section settings with that one mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.journey != nil {
                Text(String(format: "Recent sent speed: %.1f mph", session.currentRouteSpeed / 0.44704))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(session.smoothMovement
                 ? "Changes apply on the next update. Smooth movement speeds up gradually and slows for corners and stops, so the current speed can be below your target. Turn it off for a constant target speed."
                 : "Changes apply on the next update at the selected speed. Connection delays can still slow travel. Recent sent speed measures confirmed route distance over time, not another app's speed reading.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .tint(LocusTheme.accent)
    }
}

struct MovementControlsSheet: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { RouteModeMenu(); MovementSpeedControl() }
                if let route = session.activeRoute {
                    Section {
                        Text(route.source.title)
                        if let note = route.source.playbackNote(mode: session.travelMode) { Text(note).foregroundStyle(LocusTheme.statusWarn) }
                        Text("Walk, run, bike, and e-bike keep the current path. Switching to or from a car offers a new route or a speed-only change.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if session.routeRerouting {
                    Section {
                        ProgressView("Finding your new route…")
                        Button("Cancel route change") { session.cancelReroute() }
                    }
                }
            }
            .shiftScreen().loggedNavigationTitle("Mode & speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

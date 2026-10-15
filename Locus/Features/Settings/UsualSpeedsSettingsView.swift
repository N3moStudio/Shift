import SwiftUI

struct UsualSpeedsSettingsView: View {
    @EnvironmentObject private var session: SpoofSession
    @State private var restorePresets = false

    var body: some View {
        List {
            Section {
                Text("Your presets for Reset speed. Active trips keep their current speed.").font(.footnote).foregroundStyle(.secondary)
            }.shiftSettingsRows()
            ForEach(TravelMode.allCases) { mode in
                Section {
                    HStack {
                        Label(mode.title, systemImage: mode.icon)
                        Spacer()
                        Text(String(format: "%.1f mph", session.usualSpeedMPH(for: mode)))
                            .monospacedDigit().bold()
                    }
                    Slider(value: Binding(
                        get: { session.usualSpeedMPH(for: mode) },
                        set: { session.setUsualSpeedMPH($0, for: mode) }
                    ), in: mode.speedRangeMPH, step: mode == .walk || mode == .run ? 0.1 : 1)
                    .accessibilityLabel("\(mode.title) usual speed")
                    Text(String(format: "Allowed range: %.0f–%.0f mph", mode.speedRangeMPH.lowerBound, mode.speedRangeMPH.upperBound))
                        .font(.caption).foregroundStyle(.secondary)
                }.shiftSettingsRows()
            }
            Section {
                Button("Restore starting presets") { restorePresets = true }
            } footer: {
                Text("Walk 3 · Run 6 · Bike 12 · E-bike 15 · Car 25 mph")
            }.shiftSettingsRows()
        }
        .shiftSettingsScreen().loggedNavigationTitle("Usual speeds")
        .navigationBarTitleDisplayMode(.inline)
        .loggedConfirmationDialog("Restore starting speed presets?", isPresented: $restorePresets, titleVisibility: .visible) {
            Button("Restore presets") { session.restoreStartingUsualSpeeds() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your last used speeds and any moving route stay as they are until you tap Reset speed.")
        }
    }
}

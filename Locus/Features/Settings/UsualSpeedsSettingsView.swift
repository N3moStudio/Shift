import SwiftUI

struct UsualSpeedsSettingsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var preferences: SessionPreferences
    @State private var restorePresets = false

    var body: some View {
        List {
            Section {
                Picker("Speed units", selection: $preferences.speedUnit) {
                    ForEach(SpeedUnit.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Applies throughout Shift. Switching units keeps your actual speed and saved trips unchanged.")
            }.shiftSettingsRows()
            Section {
                Text("Your presets for Reset speed. Active trips keep their current speed.").font(.footnote).foregroundStyle(.secondary)
            }.shiftSettingsRows()
            ForEach(TravelMode.allCases) { mode in
                Section {
                    HStack {
                        Label(mode.title, systemImage: mode.icon)
                        Spacer()
                        Text(preferences.speedUnit.formatted(mph: session.usualSpeedMPH(for: mode)))
                            .monospacedDigit().bold()
                    }
                    SpeedSlider(mph: Binding(get: { session.usualSpeedMPH(for: mode) },
                                             set: { session.setUsualSpeedMPH($0, for: mode) }), mode: mode)
                    Text("Allowed range: \(preferences.speedUnit.rangeLabel(for: mode))")
                        .font(.caption).foregroundStyle(.secondary)
                }.shiftSettingsRows()
            }
            Section {
                Button("Restore starting presets") { restorePresets = true }
            } footer: {
                Text(TravelMode.allCases.map { "\($0.title) \(preferences.speedUnit.formatted(mph: UsualSpeedRules.value(for: $0, stored: [:])))" }.joined(separator: " · "))
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

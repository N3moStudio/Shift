import SwiftUI
import UIKit

struct SessionSettingsSections: View {
    enum Category { case activity, warnings, connection }
    var category: Category = .activity
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var preferences: SessionPreferences
    var body: some View {
        if category == .activity {
            Section("Preview") { ShiftActivityPreview() }.listRowBackground(Color.clear)
            Section {
                Toggle(isOn: $preferences.liveActivities) {
                    Label("Enable Live Activities", systemImage: "platter.filled.top.iphone")
                }
                ActivityAvailabilityRow(controller: session.activity)
            } footer: { Text("Controls the Lock Screen and Dynamic Island together.") }.shiftSettingsRows()
            if !preferences.liveActivities {
                Section { Text("Enable Live Activities to change the Lock Screen and Dynamic Island options.").font(.subheadline).foregroundStyle(.secondary) }.shiftSettingsRows()
            }
            Section("Lock Screen") {
                Toggle("Hide location name", isOn: $preferences.hideLocation)
                Toggle("Show route progress", isOn: $preferences.lockScreenProgress)
            }.shiftSettingsRows().disabled(!preferences.liveActivities)
            Section("Dynamic Island") {
                Toggle("Hide location name", isOn: $preferences.hideIslandLocation)
                Toggle("Show route progress", isOn: $preferences.islandProgress)
                Toggle("Show update timer", isOn: $preferences.islandTimer)
            }.shiftSettingsRows().disabled(!preferences.liveActivities)
            Section {
                SettingsHelp(lines: [
                    "Touch and hold the Dynamic Island for details. iOS decides where the activity appears.",
                    "Use the tag on the map to name a spot. That name covers about 5 meters. Library → Areas can cover a bigger place.",
                    "Names only change what Shift displays. They do not rename a place in Find My or other apps."
                ])
            }.shiftSettingsRows()
        }
        if category == .warnings {
            Section {
                Toggle("Connection warnings", isOn: $preferences.connectionAlerts)
                Picker("Session reminder", selection: $preferences.reminderMinutes) {
                    Text("Off").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
                if !session.notificationPermission {
                    Button("Enable notifications") { session.enableNotifications() }
                    Button("Open iPhone notification settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                SettingsHelp(lines: [
                    "Shift warns you when it detects a connection problem. It can only check while iOS lets it run.",
                    "Focus or notification settings can silence warnings. A reminder never stops your session."
                ])
            }.shiftSettingsRows()
        }
        if category == .connection {
            Section("Connection checks") {
                Stepper(value: $preferences.connectionCheckSeconds, in: 3...15) {
                    LabeledContent("Check every", value: "\(preferences.connectionCheckSeconds) seconds")
                }.frame(minHeight: 44)
                Text("Updates Shift’s connection status, Live Activity, and Dynamic Island. Shorter intervals use more battery. Apple’s Find My refresh timing is separate.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.shiftSettingsRows()
            Section("Status") {
                ForegroundTimeline { _ in
                    LabeledContent("Connection") { Text(session.effectivePhase.title).foregroundStyle(session.effectivePhase.color) }
                }
                if let last = session.lastConfirmedAt {
                    LabeledContent("iPhone accepted update") { Text(last, style: .relative) }
                }
                if let error = session.lastError { Text(error).font(.footnote).foregroundStyle(LocusTheme.statusWarn) }
                if session.reopenedWithoutConnection { Text(session.recoveryExplanation).font(.footnote) }
                if session.hasSession { SessionRetryButton().disabled(session.isBusy) }
                SettingsHelp(title: "Connection help", lines: [
                    "An accepted update means your iPhone received the command. It does not confirm what another app shows.",
                    "Airplane mode can leave the last location in place. You can only move it or clear it while the local connection still works.",
                    "To return to your real location, keep LocalDevVPN on and tap Stop spoofing. If the connection was lost, reconnect on Wi-Fi first.",
                    "Pause route and End route stop movement but keep your last location.",
                    "If no reply arrives within your check interval plus 7 seconds, status becomes unverified. Warnings may wait if iOS has paused Shift."
                ])
            }.shiftSettingsRows()
        }
    }


}

private struct ActivityAvailabilityRow: View {
    @ObservedObject var controller: SessionActivityController
    var body: some View {
        if let issue = controller.issue {
            Label(issue, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Static samples respond to preferences without starting an activity or timer.
private struct ShiftActivityPreview: View {
    @EnvironmentObject private var preferences: SessionPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                ShiftWidgetBrand()
                Spacer()
                Text("SAMPLE").font(.footnote.weight(.semibold)).tracking(1)
            }
            Text(preferences.hideLocation ? "Location hidden" : "Home").font(.title2.bold())
            Label("iPhone accepted update", systemImage: "checkmark.circle").font(.subheadline)
            if preferences.lockScreenProgress { ProgressView(value: 0.42).tint(ShiftPalette.color(.accent, style: preferences.visualStyle, dark: true)) }
            Divider().overlay(Color.white.opacity(0.2))
            VStack(alignment: .leading, spacing: 6) {
                Text("Dynamic Island").font(.subheadline.weight(.semibold))
                if !preferences.hideIslandLocation { Text("Home").font(.subheadline) }
                if preferences.islandProgress { ProgressView(value: 0.42).tint(.white) }
                if preferences.islandTimer { Text("Last sent 12 seconds ago").font(.footnote.monospacedDigit()) }
            }
        }.foregroundStyle(.white).padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShiftPalette.color(.canvas, style: preferences.visualStyle, dark: true), in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .combine)
    }
}

import SwiftUI

struct PrivacySettingsSection: View {
    @EnvironmentObject private var preferences: SessionPreferences
    @EnvironmentObject private var protection: AppPrivacyController
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var library: TripLibrary
    @State private var deletion: Deletion?

    private enum Deletion: String, Identifiable {
        case recents, stopSaving, favorites, trips
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recents: return "Clear recent locations?"
            case .stopSaving: return "Stop saving and clear recent locations?"
            case .favorites: return "Delete all saved favorites?"
            case .trips: return "Delete all saved trips?"
            }
        }
    }

    var body: some View {
        Section {
            Toggle("Require Face ID or passcode", isOn: Binding(
                get: { preferences.appLockEnabled },
                set: { protection.setProtectionEnabled($0) }
            )).disabled(protection.isAuthenticating)
            Toggle("Hide Shift Contents in App Switcher", isOn: Binding(
                get: { preferences.appLockEnabled || preferences.hideInAppSwitcher },
                set: { preferences.hideInAppSwitcher = $0 }
            ))
                .disabled(preferences.appLockEnabled)
            if preferences.appLockEnabled {
                Text("App protection always covers Shift while it is inactive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsHelp(lines: [
                "App Switcher hiding covers Shift when you leave it. Face ID falls back to your iPhone passcode.",
                "These options are designed to keep a session running, but background testing is unfinished. Leave them off if reliability is your priority.",
                "Lock Screen and Dynamic Island privacy are in Settings → Live Activities."
            ])
            if let error = protection.error {
                Text(error).font(.footnote).foregroundStyle(LocusTheme.statusWarn)
            }
        } header: {
            Text("App privacy")
        } footer: {
            if preferences.appLockEnabled || preferences.hideInAppSwitcher {
                Text("Background reliability is still being tested with these options on.")
            }
        }.shiftSettingsRows()

        Section {
            Toggle("Don't save recent locations", isOn: Binding(
                get: { !preferences.saveRecentLocations },
                set: { stopSaving in
                    if stopSaving { deletion = .stopSaving }
                    else { preferences.saveRecentLocations = true }
                }
            ))
            Picker("Delete recents", selection: $preferences.recentHistoryRetention) {
                ForEach(RecentHistoryRetention.allCases) { option in Text(option.title).tag(option) }
            }.disabled(!preferences.saveRecentLocations)
            Button("Clear recent locations", role: .destructive) { deletion = .recents }
                .disabled(session.recents.isEmpty)
            Button("Delete saved favorites…", role: .destructive) { deletion = .favorites }
                .disabled(session.favorites.isEmpty)
            Button("Delete saved trips…", role: .destructive) { deletion = .trips }
                .disabled(library.trips.isEmpty && library.error == nil)
            SettingsHelp(title: "About history", lines: [
                "Your history stays on this phone. Old recents are removed when Shift is running or you reopen it.",
                "Choosing a time limit also clears old entries that have no date. Saved favorites and trips are kept separately.",
                "Shift has no account or analytics. Apple Maps uses Apple services for maps, search, and routes."
            ])
        } header: {
            Text("History & saved places")
        } footer: {
            Text("Clearing recents keeps your saved places and trips.")
        }.shiftSettingsRows()
        .loggedConfirmationDialog(deletion?.title ?? "Clear history?", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible) {
            if let deletion {
                Button(deletion == .stopSaving ? "Stop saving & clear" : "Delete", role: .destructive) { perform(deletion) }
            }
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: {
            if deletion == .favorites { Text("Permanently deletes saved favorites, including favorites in Recently Deleted. Recent locations, trips, and an active route are kept. This cannot be undone.") }
            else if deletion == .trips { Text("Permanently deletes saved trips, including trips in Recently Deleted. Favorites, recent locations, and an active route are kept. This cannot be undone.") }
            else { Text("This clears recent location history. Your saved favorites, saved trips, and an active route are kept.") }
        }
    }

    private func perform(_ action: Deletion) {
        switch action {
        case .recents: session.clearRecentHistory()
        case .stopSaving:
            preferences.saveRecentLocations = false
            session.clearRecentHistory()
        case .favorites: session.clearFavorites()
        case .trips:
            if !library.clearAll() { session.lastError = library.error }
        }
        deletion = nil
    }
}

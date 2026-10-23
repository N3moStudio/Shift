import SwiftUI
import UIKit

@main
struct LocusApp: App {
    @StateObject private var session = SpoofSession()
    @StateObject private var pairing = PairingStore()
    @StateObject private var preferences = SessionPreferences.shared
    @StateObject private var privacy = AppPrivacyController()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SetupGate.defaultsKey) private var setupComplete = false
    @AppStorage(SetupGate.deferredKey) private var setupDeferred = false
    @State private var pendingShortcut: LocusShortcut?
    @StateObject private var notificationNavigation = SessionNotificationNavigation.shared
    @State private var pendingImports: [PendingImport] = []

    /// Skipping opens the map without claiming the connection has been verified.
    private var showMap: Bool {
        setupComplete || setupDeferred
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showMap {
                    RootView(incomingShortcut: $pendingShortcut, incomingSessionDetails: $notificationNavigation.pendingSessionDetails)
                } else {
                    SetupFlowView(initialStep: SetupGate.initialStep(hasPairingFile: pairing.hasPairingFile), onFinished: {
                        finishInitialSetup(verified: true)
                    }, onSkip: {
                        finishInitialSetup(verified: false)
                    })
                }
            }
            .opacity(privacy.access.isLocked ? 0 : 1)
            .allowsHitTesting(!privacy.access.isLocked)
            .accessibilityHidden(privacy.access.isLocked)
            .environmentObject(session)
            .environmentObject(session.recovery)
            .environmentObject(session.reliability)
            .environmentObject(pairing)
            .environmentObject(preferences)
            .environmentObject(privacy)
            .background(PrivacyWindowAnchor(controller: privacy).frame(width: 0, height: 0))
            .background(DeveloperTouchAnchor().frame(width: 0, height: 0))
            .privacySensitive()
            .environment(\.shiftVisualStyle, preferences.visualStyle)
            .environment(\.shiftIconDesign, preferences.iconSelection.design)
            .background(ShiftAppearanceAnchor(style: preferences.visualStyle).frame(width: 0, height: 0))
            .preferredColorScheme(preferences.colorScheme)
            .tint(ShiftPalette.color(.accent, style: preferences.visualStyle))
            .onChange(of: scenePhase) { _, phase in
                DeveloperLogStore.shared.record("scene_changed", ["phase": String(describing: phase)])
                DeveloperLogStore.shared.maintenance(flush: phase != .active)
                privacy.sceneChanged(phase)
                if phase == .inactive { session.becameInactive() }
                if phase == .active {
                    DeveloperLogObserver.shared.snapshot(session: session)
                    ShiftIconController.shared.refresh()
                    session.becameActive(pairing: pairing)
                    session.refreshRecentHistory()
                    RecentlyDeletedStore.shared.prune()
                    SessionDiagnostics.shared.recordAppActivity(isActive: true)
                    drainIncoming()
                }
                if phase == .background {
                    session.verification.cancel()
                    session.enteredBackground()
                    SessionDiagnostics.shared.recordAppActivity(isActive: false)
                }
            }
            .onChange(of: preferences.appLockEnabled) { _, _ in privacy.preferencesChanged() }
            .onChange(of: preferences.hideInAppSwitcher) { _, _ in privacy.preferencesChanged() }
            .onChange(of: preferences.saveRecentLocations) { _, _ in session.refreshRecentHistory() }
            .onChange(of: preferences.recentHistoryRetention) { _, _ in session.refreshRecentHistory() }
            .onChange(of: privacy.canOpenContent) { _, allowed in if allowed { drainIncoming() } }
            .onChange(of: showMap) { _, _ in drainIncoming() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    DeveloperLogStore.shared.maintenance()
                    DeveloperLogObserver.shared.snapshot(session: session)
                    if preferences.recentHistoryRetention != .forever { session.refreshRecentHistory() }
                }
            }
            .onChange(of: preferences.visualStyle) { _, _ in session.appearanceChanged() }
            .onChange(of: preferences.iconSelection) { _, _ in session.appearanceChanged() }
            .onChange(of: preferences.liveActivities) { _, _ in session.preferencesChanged() }
            .onChange(of: preferences.connectionCheckSeconds) { _, _ in session.connectionCheckIntervalChanged() }
            .onChange(of: preferences.hideLocation) { _, _ in session.preferencesChanged() }
            .onChange(of: preferences.hideIslandLocation) { _, _ in session.preferencesChanged() }
            .onChange(of: preferences.lockScreenProgress) { _, _ in session.preferencesChanged() }
            .onChange(of: preferences.islandProgress) { _, _ in session.preferencesChanged() }
            .onChange(of: preferences.islandTimer) { _, _ in session.preferencesChanged() }
            .onChange(of: preferences.connectionAlerts) { _, enabled in
                session.preferencesChanged()
                if enabled { session.enableNotifications() }
            }
            .onChange(of: preferences.reminderMinutes) { _, _ in session.enableNotifications() }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                session.updatePowerState()
            }
            .onOpenURL { url in
                if ["shift", "locus"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased() == "session" {
                    notificationNavigation.pendingSessionDetails = true
                } else { queueIncoming(url) }
            }
            .onAppear {
                ShiftIconController.shared.refresh()
                preferences.publishAppearance()
                UIDevice.current.isBatteryMonitoringEnabled = true
                SessionDiagnostics.shared.observe(session: session, pairing: pairing)
                DeveloperLogObserver.shared.start(session: session)
                privacy.sceneChanged(scenePhase)
                session.becameActive(pairing: pairing)
                session.refreshRecentHistory()
            }
        }
    }

    private func finishInitialSetup(verified: Bool) {
        if verified {
            SetupGate.markComplete()
            setupComplete = true
            setupDeferred = false
        } else {
            SetupGate.markDeferred()
            setupDeferred = true
        }
    }

    private struct PendingImport {
        let url: URL
        let holdsSecurityScope: Bool
    }

    private func queueIncoming(_ url: URL) {
        if let shortcut = LocusShortcut(url: url) { pendingShortcut = shortcut; drainIncoming(); return }
        guard url.isFileURL, ["plist", "mobiledevicepairing", "mobiledevicepair", "gpx"].contains(url.pathExtension.lowercased()) else { return }
        let item = PendingImport(url: url, holdsSecurityScope: url.startAccessingSecurityScopedResource())
        if pendingImports.count == 5 {
            let oldest = pendingImports.removeFirst()
            if oldest.holdsSecurityScope { oldest.url.stopAccessingSecurityScopedResource() }
        }
        pendingImports.append(item)
        drainIncoming()
    }

    private func drainIncoming() {
        guard privacy.canOpenContent else { return }
        // A later run-loop turn lets the map install its import receiver after
        // setup/unlock. Recheck access before processing each queued document.
        DispatchQueue.main.async {
            guard privacy.canOpenContent else { return }
            while let index = pendingImports.firstIndex(where: { showMap || $0.url.pathExtension.lowercased() != "gpx" }) {
                let item = pendingImports.remove(at: index)
                handleIncoming(item.url)
                if item.holdsSecurityScope { item.url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private func handleIncoming(_ url: URL) {
        guard privacy.canOpenContent else { return }
        let ext = url.pathExtension.lowercased()
        if ["plist", "mobiledevicepairing", "mobiledevicepair"].contains(ext) {
            guard !session.hasSession, !session.isBusy else {
                session.lastError = "Stop spoofing before replacing this iPhone’s pairing file."
                return
            }
            do { try pairing.importPairing(from: url) }
            catch { session.lastError = error.localizedDescription }
        } else if ext == "gpx" {
            NotificationCenter.default.post(name: .locusImportGPX, object: url)
        }
    }
}

extension Notification.Name {
    static let locusImportGPX = Notification.Name("locusImportGPX")
}

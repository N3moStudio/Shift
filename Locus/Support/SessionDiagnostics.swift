import Combine
import Foundation
import UIKit

/// An in-memory, allowlisted event recorder. No file, network, coordinate,
/// user-entered name, pairing contents, or raw error is ever read here.
@MainActor
final class SessionDiagnostics: ObservableObject {
    static let shared = SessionDiagnostics()
    @Published var recordingEnabled: Bool {
        didSet {
            guard recordingEnabled != oldValue else { return }
            UserDefaults.standard.set(recordingEnabled, forKey: "locus.keepTroubleshootingEvents")
            if recordingEnabled { record(.recordingResumed) }
            else { clear() }
        }
    }
    private var buffer = DiagnosticBuffer(uptime: ProcessInfo.processInfo.systemUptime)
    private var observedSession: ObjectIdentifier?
    private var subscriptions = Set<AnyCancellable>()
    private var lastAppActive: Bool?

    private init() {
        recordingEnabled = UserDefaults.standard.object(forKey: "locus.keepTroubleshootingEvents") as? Bool ?? true
    }

    func observe(session: SpoofSession, pairing: PairingStore) {
        guard observedSession != ObjectIdentifier(session) else { return }
        observedSession = ObjectIdentifier(session)
        subscriptions.removeAll()
        record(.opened)
        session.$status.map(\.phase).removeDuplicates().sink { [weak self] phase in
            self?.record(.phase(phase))
        }.store(in: &subscriptions)
        session.$journey.map { $0?.state }.removeDuplicates().sink { [weak self] state in
            self?.record(.route(state))
        }.store(in: &subscriptions)
        session.$joystickActive.removeDuplicates().sink { [weak self] enabled in
            self?.record(.joystick(enabled))
        }.store(in: &subscriptions)
        session.$lowPower.removeDuplicates().sink { [weak self] enabled in
            self?.record(.lowPower(enabled))
        }.store(in: &subscriptions)
        session.$lastConfirmedAt.compactMap { $0 }.removeDuplicates().sink { [weak self] _ in
            guard let self, self.recordingEnabled else { return }
            self.buffer.commandSucceeded(uptime: ProcessInfo.processInfo.systemUptime)
        }.store(in: &subscriptions)
        // Pairing state is read as a boolean only; no file URL or contents.
        pairing.$hasPairingFile.removeDuplicates().sink { [weak self] available in
            self?.record(available ? .pairingAvailable : .pairingMissing)
        }.store(in: &subscriptions)
    }

    func recordAppActivity(isActive: Bool) {
        guard lastAppActive != isActive else { return }
        lastAppActive = isActive
        record(isActive ? .foreground : .background)
    }

    private func record(_ kind: DiagnosticEventKind) {
        guard recordingEnabled else { return }
        buffer.record(kind, uptime: ProcessInfo.processInfo.systemUptime)
    }

    func clear() {
        buffer.clear(uptime: ProcessInfo.processInfo.systemUptime)
    }

    func report(session: SpoofSession, pairing: PairingStore, category: ProblemCategory,
                includeNotes: Bool, notes: String) -> String {
        let preferences = session.preferences
        let context = ProblemReportContext(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            systemVersion: UIDevice.current.systemVersion,
            isTablet: UIDevice.current.userInterfaceIdiom == .pad,
            phase: session.effectivePhase, routeState: session.journey?.state,
            settings: [.lowPower: session.lowPower, .smooth: session.smoothMovement,
                       .glass: preferences.glassPanel, .liveActivity: preferences.liveActivities,
                       .hideLockName: preferences.hideLocation, .hideIslandName: preferences.hideIslandLocation,
                       .pairing: pairing.hasPairingFile, .tunnel: LocalDevVPN.hasMatchingInterface,
                       .joystick: session.joystickActive, .recording: recordingEnabled,
                       .appLock: preferences.appLockEnabled, .switcherCover: preferences.appLockEnabled || preferences.hideInAppSwitcher,
                       .saveRecents: preferences.saveRecentLocations], historyRetention: preferences.recentHistoryRetention)
        return PrivateProblemReport.render(context: context, buffer: buffer, category: category,
            uptime: ProcessInfo.processInfo.systemUptime, includeNotes: includeNotes, notes: notes)
    }
}

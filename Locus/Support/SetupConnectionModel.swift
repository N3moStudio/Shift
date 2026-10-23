import Combine
import Foundation
import Network

@MainActor
final class SetupConnectionModel: ObservableObject {
    @Published private(set) var wifiAvailable: Bool?
    @Published private(set) var tunnelDetected = false
    @Published private(set) var vpnInstalled = false
    @Published private(set) var lifecycle = SetupCheckLifecycle() {
        didSet { DeveloperLogStore.shared.record("setup_check_state", ["state": String(describing: lifecycle.state)]) }
    }
    @Published private(set) var nativeCheckOutstanding = false

    private var monitor: NWPathMonitor?
    private var monitorID = UUID()
    private var refreshTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cancellation: SetupConnectionCancellation?
    private var observedTunnelAddress: String?

    var checking: Bool { lifecycle.state == .checking }
    var issue: SetupIssue? {
        if case .failed(let issue) = lifecycle.state { return issue }
        return nil
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        if wifiAvailable != nil { wifiAvailable = nil }
        let id = UUID()
        monitorID = id
        // A VPN interface is not evidence of Wi-Fi. Observe Wi-Fi separately.
        let observer = NWPathMonitor(requiredInterfaceType: .wifi)
        observer.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor in
                guard let self, self.monitorID == id else { return }
                if self.wifiAvailable != available { self.wifiAvailable = available }
                if !available { self.invalidateIfNeeded(.wifiRequired) }
            }
        }
        monitor = observer
        observer.start(queue: DispatchQueue(label: "com.n3mostudio.shift.setup-wifi"))
        refreshTunnel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                self.refreshTunnel()
                if case .verified(let date) = self.lifecycle.state,
                   Date().timeIntervalSince(date) >= SetupReadiness.verificationLifetime {
                    self.lifecycle.invalidate(.verificationExpired)
                }
            }
        }
    }

    func stopMonitoring() {
        monitorID = UUID()
        monitor?.cancel()
        monitor = nil
        refreshTask?.cancel()
        refreshTask = nil
        cancelCheck()
    }

    func refreshTunnel() {
        let address = TunnelConfig.targetIP
        if let previous = observedTunnelAddress, previous != address { invalidateIfNeeded(.configurationChanged) }
        observedTunnelAddress = address
        let detected = LocalDevVPN.hasMatchingInterface
        let installed = LocalDevVPN.isInstalled
        if detected != tunnelDetected { tunnelDetected = detected }
        if installed != vpnInstalled { vpnInstalled = installed }
        // A missing interface hint must not cancel a real connection check.
    }

    func cancelCheck() {
        cancellation?.cancel()
        timeoutTask?.cancel()
        timeoutTask = nil
        if checking { lifecycle.invalidate(.cancelled) }
    }

    func leftForeground() {
        cancelCheck()
        if case .verified = lifecycle.state { lifecycle.invalidate(.verificationExpired) }
    }

    func canFinish(pairing: PairingStore, session: SpoofSession, now: Date = Date()) -> Bool {
        lifecycle.isVerified(now: now, prerequisite: prerequisite(pairing: pairing, session: session),
                             configuration: SetupConfiguration(pairingRevision: pairing.revision, tunnelAddress: TunnelConfig.targetIP))
    }

    func pairingDidChange() { invalidateIfNeeded(.configurationChanged) }

    func prerequisite(pairing: PairingStore, session: SpoofSession) -> SetupIssue? {
        SetupReadiness.prerequisite(wifiAvailable: wifiAvailable, tunnelDetected: tunnelDetected,
                                   hasPairing: pairing.hasPairingFile, hasSession: session.hasSession || session.isBusy)
    }

    func startCheck(pairing: PairingStore, session: SpoofSession) {
        DeveloperLogStore.shared.record("setup_check_tapped")
        refreshTunnel()
        guard !nativeCheckOutstanding else {
            lifecycle.invalidate(.previousCheckRunning)
            return
        }
        if let issue = prerequisite(pairing: pairing, session: session) {
            lifecycle.invalidate(issue)
            return
        }
        let configuration = SetupConfiguration(pairingRevision: pairing.revision, tunnelAddress: TunnelConfig.targetIP)
        let id = lifecycle.begin(configuration: configuration)
        let token = SetupConnectionCancellation()
        cancellation = token
        nativeCheckOutstanding = true
        let path = pairing.pairingPath
        let address = configuration.tunnelAddress
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.lifecycle.attemptID == id else { return }
            token.cancel()
            self.lifecycle.invalidate(.timedOut)
        }
        Task { [weak self] in
            let issue = await LocationEngine.checkConnection(pairingPath: path, deviceIP: address, cancellation: token)
            guard let self else { return }
            self.nativeCheckOutstanding = false
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.cancellation = nil
            guard self.lifecycle.attemptID == id else { return }
            self.refreshTunnel()
            let current = SetupConfiguration(pairingRevision: pairing.revision, tunnelAddress: TunnelConfig.targetIP)
            let resultIssue: SetupIssue? = current == configuration
                ? (issue ?? self.prerequisite(pairing: pairing, session: session)) : .configurationChanged
            self.lifecycle.finish(id, issue: resultIssue, now: Date())
        }
    }

    private func invalidateIfNeeded(_ issue: SetupIssue) {
        switch lifecycle.state {
        case .checking, .verified:
            cancellation?.cancel()
            timeoutTask?.cancel()
            timeoutTask = nil
            lifecycle.invalidate(issue)
        case .idle, .failed: break
        }
    }
}

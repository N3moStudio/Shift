import SwiftUI

/// One connection checklist. Verification still uses a temporary handshake;
/// simplifying the presentation never skips prerequisites or sends a location.
struct SetupFlowView: View {
    typealias Step = SetupStage
    @EnvironmentObject private var preferences: SessionPreferences
    @Environment(\.shiftVisualStyle) private var style
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = SetupConnectionModel()
    @StateObject private var pairingHost = PairOnDeviceService()
    @State private var showImporter = false
    @State private var importHelp: String?
    @State private var wantsNewPairing = false
    @State private var pairingOptionsExpanded: Bool
    var onFinished: () -> Void
    var onSkip: (() -> Void)?

    init(initialStep: Step = .wifi, onFinished: @escaping () -> Void, onSkip: (() -> Void)? = nil) {
        _pairingOptionsExpanded = State(initialValue: initialStep == .pairing)
        self.onFinished = onFinished
        self.onSkip = onSkip
    }

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
    private var setupBlocked: Bool { session.hasSession || session.isBusy }
    private var verified: Bool { !needsPairing && connection.canFinish(pairing: pairing, session: session) }
    private var needsPairing: Bool { !pairing.hasPairingFile || wantsNewPairing }
    private var pairingFailed: Bool {
        if case .failed = pairingHost.phase { return true }
        return false
    }
    private var wifiStatus: String {
        guard let available = connection.wifiAvailable else { return "Checking…" }
        return available ? "Connected" : "Not connected"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                setupHeading

                VStack(spacing: 0) {
                    connectionRow("Wi-Fi", status: wifiStatus, symbol: "wifi",
                                  complete: connection.wifiAvailable == true)
                    rowDivider
                    Button { LocalDevVPN.openOrInstall() } label: {
                        connectionRow("LocalDevVPN",
                            status: verified ? "Verified" : connection.tunnelDetected ? "Tunnel detected" : connection.vpnInstalled ? "Open" : "Get",
                            symbol: "lock.shield", complete: verified, opensApp: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(connection.vpnInstalled ? "Opens LocalDevVPN." : "Opens the LocalDevVPN download.")
                    .disabled(setupBlocked || connection.checking)
                    rowDivider
                    connectionRow("iPhone pairing", status: pairing.hasPairingFile ? "Saved" : "Not paired",
                                  symbol: "iphone", complete: pairing.hasPairingFile)
                }
                .background(ShiftPalette.color(.surface, style: style), in: RoundedRectangle(cornerRadius: style.cornerRadius))

                if setupBlocked { issueCard(.activeSession) }
                else if let issue = connection.issue { issueCard(issue) }

                if !setupBlocked {
                    if pairingHost.isBusy || pairingFailed { pairingProgress }
                    if let importHelp {
                        Label(importHelp, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(LocusTheme.statusWarn)
                    }
                    DisclosureGroup(isExpanded: $pairingOptionsExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            Button("Import pairing file") { showImporter = true }.frame(minHeight: 44)
                            Button("Paste pairing file") {
                                do { try pairing.importPairingFromClipboard(); importHelp = nil; wantsNewPairing = false }
                                catch { importHelp = "Copy a valid RPPairing file and try again." }
                            }.frame(minHeight: 44)
                            if pairing.hasPairingFile && supportsOnDevicePairing {
                                Button(wantsNewPairing ? "Use saved pairing" : "Pair again") {
                                    pairingHost.resetToIdle(); wantsNewPairing.toggle()
                                }.frame(minHeight: 44)
                            }
                        }
                    } label: { Text("Pairing options").frame(minHeight: 44) }
                    .disabled(pairingHost.isBusy || connection.checking || connection.nativeCheckOutstanding)
                }
            }
            .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background { ShiftCanvas() }.tint(LocusTheme.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 4) {
                footerAction.disabled(setupBlocked)
                if let onSkip {
                    Button(SetupGate.isComplete ? "Back to map" : "Set up later") {
                        connection.cancelCheck(); pairingHost.resetToIdle(); onSkip()
                    }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
            .background(ShiftPalette.canvas)
        }
        .onAppear {
            if !SetupGate.isComplete { SetupGate.markInProgress() }
            connection.startMonitoring()
        }
        .onDisappear { connection.stopMonitoring(); pairingHost.resetToIdle() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connection.refreshTunnel() }
            else if phase == .background { connection.leftForeground() }
        }
        .onChange(of: pairingHost.phase) { _, phase in
            if phase == .succeeded {
                pairing.refresh(); wantsNewPairing = false; pairingOptionsExpanded = false
            }
        }
        .onChange(of: pairing.revision) { _, _ in connection.pairingDidChange() }
        .onChange(of: setupBlocked) { _, blocked in
            if blocked { showImporter = false; connection.cancelCheck(); pairingHost.resetToIdle() }
        }
        .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(onPick: { url in
                showImporter = false
                guard !setupBlocked else { importHelp = "Stop your session before changing pairing."; return }
                do {
                    try pairing.importPairing(from: url)
                    importHelp = nil; wantsNewPairing = false; pairingOptionsExpanded = false
                } catch { importHelp = "Choose a valid RPPairing file for this iPhone." }
            }, onCancel: { showImporter = false }).ignoresSafeArea()
        }
    }

    @ViewBuilder private var setupHeading: some View {
        if style == .afterhours {
            VStack(spacing: 18) {
                ShiftAppIconPreview(selection: preferences.iconSelection, size: 88)
                Text(verified ? "You're ready." : style.heading)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-0.7)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                if style == .glacier { ShiftAppIconPreview(selection: preferences.iconSelection, size: 72) }
                Text(verified ? "You're ready." : style.heading)
                    .font(.largeTitle.bold()).tracking(-0.9).fixedSize(horizontal: false, vertical: true)
                if style == .porcelain { ShiftAppIconPreview(selection: preferences.iconSelection, size: 58) }
            }.padding(.vertical, 12)
        }
    }
    private var rowDivider: some View { Divider().padding(.leading, style == .porcelain ? 16 : 66) }

    private func connectionRow(_ title: String, status: String, symbol: String,
                               complete: Bool, opensApp: Bool = false) -> some View {
        HStack(spacing: 12) {
            ShiftRowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if complete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LocusTheme.accent).accessibilityHidden(true)
            }
            if opensApp {
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var pairingProgress: some View {
        switch pairingHost.phase {
        case .idle, .succeeded: EmptyView()
        case .failed:
            Label("Pairing failed. Try again.", systemImage: "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(LocusTheme.statusWarn)
        case .advertising:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView("Waiting to pair…")
                Text("Settings → Privacy & Security → Developer Mode → Pair with Shift")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        case .deviceConnected: ProgressView("Preparing code…")
        case .awaitingPIN(let pin):
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter in iPhone Settings").font(.headline)
                Text(pin).font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .monospacedDigit().tracking(4).foregroundStyle(LocusTheme.accent).privacySensitive()
                    .accessibilityLabel("Pairing code \(pin.map(String.init).joined(separator: " "))")
            }
        }
    }

    @ViewBuilder private var footerAction: some View {
        if connection.checking {
            ProgressView("Checking connection…").font(.subheadline)
            primaryButton("Cancel check") { connection.cancelCheck() }
        } else if connection.nativeCheckOutstanding {
            primaryButton("Finishing check…", enabled: false) { }
        } else if pairingHost.isBusy {
            primaryButton("Cancel pairing") { pairingHost.resetToIdle(); wantsNewPairing = false }
        } else if verified {
            primaryButton("Open map") {
                guard connection.canFinish(pairing: pairing, session: session) else { return }
                onFinished()
            }
        } else if connection.wifiAvailable != true {
            primaryButton(connection.wifiAvailable == nil ? "Checking Wi-Fi…" : "Connect to Wi-Fi", enabled: false) { }
        } else if needsPairing {
            if supportsOnDevicePairing {
                primaryButton("Pair iPhone") {
                    importHelp = nil; connection.cancelCheck()
                    pairingHost.acknowledgeFailure(); pairingHost.start(pairingStore: pairing)
                }
            } else { primaryButton("Import pairing file") { showImporter = true } }
        } else {
            primaryButton(connection.issue == nil ? "Check connection" : "Try again") {
                connection.startCheck(pairing: pairing, session: session)
            }
        }
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(ShiftActionStyle()).disabled(!enabled)
    }

    private func issueCard(_ issue: SetupIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(issue.title, systemImage: "exclamationmark.circle")
                .font(.headline).foregroundStyle(LocusTheme.statusWarn)
            Text(issue.setupAction).font(.subheadline).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
}

enum SetupGate {
    static let defaultsKey = "locus.setupComplete"
    static let inProgressKey = "locus.setupInProgress"
    static let deferredKey = "locus.setupDeferred"

    static var isComplete: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
    static var isInProgress: Bool { UserDefaults.standard.bool(forKey: inProgressKey) }
    static var isDeferred: Bool { UserDefaults.standard.bool(forKey: deferredKey) }

    static func markInProgress() { UserDefaults.standard.set(true, forKey: inProgressKey) }
    static func markComplete() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        UserDefaults.standard.set(false, forKey: inProgressKey)
        UserDefaults.standard.set(false, forKey: deferredKey)
    }
    static func markDeferred() {
        UserDefaults.standard.set(true, forKey: deferredKey)
        UserDefaults.standard.set(false, forKey: inProgressKey)
    }
    static func initialStep(hasPairingFile: Bool) -> SetupFlowView.Step {
        let saved = SetupStage(rawValue: UserDefaults.standard.integer(forKey: "shift.setup.lastStep")) ?? .wifi
        if saved == .ready { return .connection }
        if saved == .connection && !hasPairingFile { return .pairing }
        return saved
    }
}

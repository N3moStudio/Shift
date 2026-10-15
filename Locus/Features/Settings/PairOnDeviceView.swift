import SwiftUI

struct PairOnDeviceView: View {
    enum Mode {
        /// Settings sheet — Close toolbar, dismiss on Done.
        case sheet
        /// First-run setup — no toolbar; calls `onFinished` after success.
        case embedded
    }

    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var host = PairOnDeviceService()

    var mode: Mode = .sheet
    var onFinished: (() -> Void)?

    var body: some View {
        Group {
            if mode == .sheet {
                NavigationStack {
                    scrollContent
                        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                        .shiftScreen().loggedNavigationTitle("Pair on this iPhone")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") {
                                    host.resetToIdle()
                                    dismiss()
                                }
                            }
                        }
                }
            } else {
                scrollContent
            }
        }
        .onChange(of: host.phase) { _, phase in
            if case .succeeded = phase {
                pairing.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, host.isBusy {
                _ = host.pin
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if mode == .sheet {
                    header
                } else {
                    embeddedIntro
                }

                steps

                statusCard

                if mode == .sheet {
                    tipCard
                }

                actions
            }
            .padding(mode == .embedded ? 16 : 20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No computer needed")
                .font(.title2.weight(.bold))
            Text("Shift advertises a pairable host. iOS connects from Developer Mode, then Shift shows a 6-digit code for you to type.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var embeddedIntro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Follow these steps")
                .font(.headline)
            Text("Keep Shift open. You’ll leave briefly for Settings, then come back with a code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Tap Start pairing and allow Local Network + Location when asked.")
            step(2, "Allow notifications — the code can appear as a banner over Settings.")
            step(3, "Open Settings › Privacy & Security › Developer Mode › Pair with Shift → Pair.")
            step(4, "Enter your unlock passcode first. On the next prompt, type Shift’s 6-digit code.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(LocusTheme.onAccent)
                .frame(width: 22, height: 22)
                .background(LocusTheme.accent, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private var tipCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("If the code isn’t here yet", systemImage: "lightbulb.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LocusTheme.accentSecondary)
            Text("Keep the app listening while you confirm in Developer Mode. Don’t force-quit. If “Pair with Shift” vanishes, stop/start pairing and reopen Developer Mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.accentSecondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 14) {
            switch host.phase {
            case .idle:
                Label("Ready when you are", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            case .advertising:
                ProgressView()
                Text("Waiting for Settings…")
                    .font(.headline)
                Text("In Developer Mode tap Pair with Shift → Pair.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .deviceConnected:
                ProgressView()
                Text("iPhone connected")
                    .font(.headline)
                Text("Generating your 6-digit code…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .awaitingPIN(let pin):
                Text("Enter this code in Settings")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(pin)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .tracking(10)
                    .monospacedDigit()
                    .foregroundStyle(LocusTheme.accent)
                    .textSelection(.enabled)
                Text("Second prompt only — after your unlock passcode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .succeeded:
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(LocusTheme.statusGood)
                Text("Paired")
                    .font(.title3.weight(.bold))
                Text(mode == .embedded
                     ? "Next we’ll set up LocalDevVPN."
                     : "RPPairing file saved. Connect LocalDevVPN, then teleport.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(LocusTheme.statusWarn)
                Text("Pairing failed")
                    .font(.title3.weight(.bold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        switch host.phase {
        case .idle, .failed:
            Button {
                host.acknowledgeFailure()
                host.start(pairingStore: pairing)
            } label: {
                Text(host.phase == .idle ? "Start pairing" : "Try again")
                    .font(.headline)
                    .foregroundStyle(LocusTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(LocusTheme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        case .succeeded:
            Button {
                if let onFinished {
                    onFinished()
                } else {
                    dismiss()
                }
            } label: {
                Text(mode == .embedded ? "Continue" : "Done")
                    .font(.headline)
                    .foregroundStyle(LocusTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(LocusTheme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        case .advertising, .deviceConnected, .awaitingPIN:
            Text({
                switch host.phase {
                case .awaitingPIN: return "Type the code above into the second Settings prompt."
                case .deviceConnected: return "Connected — code coming next."
                default: return "Waiting for iOS to connect… don’t force-quit Shift."
                }
            }())
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}

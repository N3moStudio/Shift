import Foundation

enum SetupStage: Int, CaseIterable {
    case wifi, vpn, pairing, connection, ready
    static var welcome: SetupStage { .wifi }
}

/// Fixed messages keep native pairing errors, file paths, and credentials out
/// of first-run help and any diagnostic summary made from these categories.
enum SetupIssue: String, Equatable {
    case checkingWiFi, wifiRequired, vpnRequired, pairingRequired, activeSession
    case invalidAddress, pairingRejected, tunnelUnavailable, serviceUnavailable
    case timedOut, cancelled, previousCheckRunning, verificationExpired, configurationChanged

    var step: SetupStage {
        switch self {
        case .checkingWiFi, .wifiRequired: return .wifi
        case .vpnRequired, .invalidAddress, .tunnelUnavailable: return .vpn
        case .pairingRequired, .pairingRejected: return .pairing
        default: return .connection
        }
    }

    var title: String {
        switch self {
        case .checkingWiFi: return "Checking Wi-Fi"
        case .wifiRequired: return "Connect to Wi-Fi first"
        case .vpnRequired: return "Local tunnel not detected"
        case .pairingRequired: return "Pair this iPhone"
        case .activeSession: return "A location session already exists"
        case .invalidAddress: return "Check the tunnel address"
        case .pairingRejected: return "Pairing needs attention"
        case .tunnelUnavailable: return "Couldn’t reach the local tunnel"
        case .serviceUnavailable: return "Couldn’t open the developer service"
        case .timedOut: return "The connection check took too long"
        case .cancelled: return "Check cancelled"
        case .previousCheckRunning: return "The previous check is finishing"
        case .verificationExpired: return "Run a fresh connection check"
        case .configurationChanged: return "Setup changed — check again"
        }
    }

    var detail: String {
        switch self {
        case .checkingWiFi: return "Wait for the Wi-Fi check, then continue."
        case .wifiRequired: return "In iPhone Settings, open Wi-Fi and join a network. Initial connection needs Wi-Fi as well as LocalDevVPN."
        case .vpnRequired: return "Open LocalDevVPN, turn its tunnel on, then return to Shift. Wi-Fi must stay connected too."
        case .pairingRequired: return "Create a pairing on this iPhone or import its RPPairing file."
        case .activeSession: return "Return to the map and use Stop spoofing before testing setup. If Stop needs a connection, reconnect there first."
        case .invalidAddress: return "In Shift Settings, make the Tunnel IP match LocalDevVPN. Its default is 10.7.0.1."
        case .pairingRejected: return "Use a pairing file made for this iPhone. If needed, pair again, then repeat the connection check."
        case .tunnelUnavailable: return "Keep Wi-Fi connected, open LocalDevVPN and reconnect its tunnel, then try again. Check the Tunnel IP in Shift Settings if you changed it."
        case .serviceUnavailable: return "Check Developer Mode in iPhone Settings, then reconnect LocalDevVPN. If it still fails, pair this iPhone again."
        case .timedOut: return "Check Wi-Fi and LocalDevVPN. No location was sent. A pending network call may need a moment to finish before another check can start."
        case .cancelled: return "No location was sent. A pending network call may need a moment to finish before another check can start."
        case .previousCheckRunning: return "Wait a moment before trying again. You can leave setup; this check does not send or clear a location."
        case .verificationExpired: return "The earlier check has expired. Keep Wi-Fi and LocalDevVPN connected, then check again."
        case .configurationChanged: return "The pairing file or tunnel address changed. Run a new connection check using the current setup."
        }
    }

    /// First-run recovery needs an action, not another explanation of setup.
    var setupAction: String {
        switch self {
        case .checkingWiFi: return "Wait a moment."
        case .wifiRequired: return "Connect in iPhone Settings."
        case .vpnRequired, .tunnelUnavailable: return "Reconnect LocalDevVPN, then try again."
        case .pairingRequired: return "Pair this iPhone or import its pairing file."
        case .activeSession: return "Stop your session on the map first."
        case .invalidAddress: return "Match the Tunnel IP in Shift Settings to LocalDevVPN."
        case .pairingRejected: return "Import this iPhone’s pairing file or pair again."
        case .serviceUnavailable: return "Enable Developer Mode in iPhone Settings, then reconnect LocalDevVPN."
        case .timedOut: return "Check Wi-Fi and reconnect LocalDevVPN."
        case .cancelled, .previousCheckRunning: return "Wait for the current check to finish."
        case .verificationExpired, .configurationChanged: return "Check the connection again."
        }
    }
}

struct SetupConfiguration: Equatable {
    let pairingRevision: UUID
    let tunnelAddress: String
}

enum SetupReadiness {
    static let verificationLifetime: TimeInterval = 60

    static func prerequisite(wifiAvailable: Bool?, tunnelDetected: Bool, hasPairing: Bool,
                             hasSession: Bool) -> SetupIssue? {
        if hasSession { return .activeSession }
        guard let wifiAvailable else { return .checkingWiFi }
        guard wifiAvailable else { return .wifiRequired }
        // Interface enumeration is only a hint; the developer handshake is authoritative.
        guard hasPairing else { return .pairingRequired }
        return nil
    }
}

struct SetupCheckLifecycle: Equatable {
    enum State: Equatable {
        case idle, checking, verified(Date), failed(SetupIssue)
    }

    private(set) var state: State = .idle
    private(set) var attemptID: UUID?
    private(set) var configuration: SetupConfiguration?

    mutating func begin(configuration: SetupConfiguration? = nil) -> UUID {
        let id = UUID()
        attemptID = id
        state = .checking
        self.configuration = configuration
        return id
    }

    mutating func finish(_ id: UUID, issue: SetupIssue?, now: Date) {
        guard attemptID == id, state == .checking else { return }
        attemptID = nil
        state = issue.map { .failed($0) } ?? .verified(now)
        if issue != nil { configuration = nil }
    }

    mutating func invalidate(_ issue: SetupIssue) {
        attemptID = nil
        state = .failed(issue)
        configuration = nil
    }

    func isVerified(now: Date, prerequisite: SetupIssue?, configuration: SetupConfiguration? = nil) -> Bool {
        guard prerequisite == nil, self.configuration == configuration,
              case .verified(let date) = state else { return false }
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < SetupReadiness.verificationLifetime
    }
}

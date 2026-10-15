import Foundation
import idevice

/// Stops later probe stages and ignores a late response. A synchronous vendor
/// call already in progress cannot be interrupted safely from another thread.
final class SetupConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum LocationEngineError: LocalizedError {
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive

    var failedBeforeWrite: Bool {
        switch self {
        case .invalidIP, .pairingRead, .tunnelCreate, .remoteServer, .simulationCreate, .notActive: return true
        case .locationSet, .locationClear: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "Tunnel IP is invalid. Check Settings → Tunnel IP (usually 10.7.0.1)."
        case .pairingRead: return "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode."
        case .tunnelCreate: return "Could not open a new developer connection. A fresh connection needs Wi-Fi and LocalDevVPN. An existing connection can keep working after Wi-Fi disconnects."
        case .remoteServer: return "Connected to the tunnel but RemoteXPC handshake failed."
        case .simulationCreate: return "Could not open Apple’s location simulation service."
        case .locationSet: return "Failed to set simulated coordinates."
        case .locationClear: return "Failed to clear simulated location."
        case .notActive: return "No active simulation session."
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        default: return .locationSet
        }
    }
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.chrismack.locus.location", qos: .userInitiated)
    private static let setupQueue = DispatchQueue(label: "com.chrismack.locus.setup-check", qos: .userInitiated)
    private static let setupLock = NSLock()
    private static var setupCheckRunning = false

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12

    private static func logError(_ error: UnsafeMutablePointer<IdeviceFfiError>, stage: String) {
        DeveloperLogStore.shared.record("engine_error", ["stage": stage,
            "code": String(error.pointee.code), "sub_code": String(error.pointee.sub_code)])
        // The vendor's free-form message may include connection details. Keep
        // numeric diagnostics only and never read pairing contents into the log.
    }

    /// Opens an independent developer connection and closes its handles. Never
    /// sends a coordinate, clears simulation, or uses cached session handles.
    /// Callers must reject checks while any location session exists.
    static func checkConnection(pairingPath: String, deviceIP: String,
                                cancellation: SetupConnectionCancellation) async -> SetupIssue? {
        guard reserveSetupCheck() else { return .previousCheckRunning }
        return await withCheckedContinuation { continuation in
            setupQueue.async {
                let issue = probeConnection(pairingPath: pairingPath, deviceIP: deviceIP, cancellation: cancellation)
                releaseSetupCheck()
                continuation.resume(returning: issue)
            }
        }
    }

    private static func reserveSetupCheck() -> Bool {
        setupLock.lock()
        defer { setupLock.unlock() }
        guard !setupCheckRunning else { return false }
        setupCheckRunning = true
        return true
    }

    private static func releaseSetupCheck() {
        setupLock.lock()
        setupCheckRunning = false
        setupLock.unlock()
    }

    private static func probeConnection(pairingPath: String, deviceIP: String,
                                         cancellation: SetupConnectionCancellation) -> SetupIssue? {
        guard !cancellation.isCancelled else { return .cancelled }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return .invalidAddress }

        var pairingHandle: OpaquePointer?
        if let error = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(error)
            return .pairingRejected
        }
        guard let pairingHandle else { return .pairingRejected }
        defer { rp_pairing_file_free(pairingHandle) }

        var probeAdapter: OpaquePointer?
        var probeHandshake: OpaquePointer?
        var probeServer: OpaquePointer?
        defer {
            if let probeServer { remote_server_free(probeServer) }
            if let probeHandshake { rsd_handshake_free(probeHandshake) }
            if let probeAdapter { adapter_free(probeAdapter) }
        }
        guard !cancellation.isCancelled else { return .cancelled }
        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.stride), "ShiftSetupCheck",
                    pairingHandle, nil, nil, &probeAdapter, &probeHandshake)
            }
        }
        if let providerError {
            idevice_error_free(providerError)
            return .tunnelUnavailable
        }
        guard !cancellation.isCancelled else { return .cancelled }
        if let error = remote_server_connect_rsd(probeAdapter, probeHandshake, &probeServer) {
            idevice_error_free(error)
            return .serviceUnavailable
        }
        guard !cancellation.isCancelled else { return .cancelled }
        return probeServer == nil ? .serviceUnavailable : nil
    }

    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async -> Result<Void, LocationEngineError> {
        await withCheckedContinuation { continuation in
            queue.async {
                let code = setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
                let result: Result<Void, LocationEngineError> = code == ok ? .success(()) : .failure(.from(code: code))
                continuation.resume(returning: result)
            }
        }
    }

    static func clear(pairingPath: String, deviceIP: String) async -> Result<Void, LocationEngineError> {
        await withCheckedContinuation { continuation in
            queue.async {
                // Reopen the service after a failure so Stop can still clear a
                // simulation. Clearing must not set a new coordinate first.
                let connectionCode = connectLocked(pairingPath: pairingPath, deviceIP: deviceIP)
                let code = connectionCode == ok ? clearLocked() : connectionCode
                let result: Result<Void, LocationEngineError> = code == ok ? .success(()) : .failure(.from(code: code))
                continuation.resume(returning: result)
            }
        }
    }

    private static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) -> Int32 {
        let code = connectLocked(pairingPath: pairingPath, deviceIP: deviceIP)
        guard code == ok, let locationSimulation else { return code == ok ? simulationCreate : code }
        if let err = location_simulation_set(locationSimulation, latitude, longitude) {
            logError(err, stage: "set")
            idevice_error_free(err)
            cleanup()
            return locationSet
        }
        return ok
    }

    private static func connectLocked(pairingPath: String, deviceIP: String) -> Int32 {
        if locationSimulation != nil { return ok }
        DeveloperLogStore.shared.record("engine_opening_new_connection")
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return invalidIP }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            logError(pairingError, stage: "read_credentials")
            idevice_error_free(pairingError)
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "ShiftLocation",
                    pairingHandle,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if let providerError {
            idevice_error_free(providerError)
            cleanup()
            return tunnelCreate
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            logError(remoteServerError, stage: "remote_handshake")
            idevice_error_free(remoteServerError)
            cleanup()
            return remoteServerCode
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            logError(simError, stage: "open_simulation")
            idevice_error_free(simError)
            cleanup()
            return simulationCreate
        }
        // location_simulation_new consumes/owns remote server lifecycle alongside handle
        remoteServer = nil

        return ok
    }

    private static func clearLocked() -> Int32 {
        guard let locationSimulation else { return locationClear }
        let err = location_simulation_clear(locationSimulation)
        cleanup()
        if let err {
            logError(err, stage: "clear")
            idevice_error_free(err)
            return locationClear
        }
        return ok
    }
}

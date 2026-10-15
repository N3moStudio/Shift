import Foundation
import Network

/// Public-facing pairable-host listener.
///
/// Uses Network.framework `NWListener` + Bonjour (what iOS 27 Developer Mode
/// browses). Inbound connections are relayed to the Rust pairable-host on
/// 127.0.0.1 so accept() still completes while Settings is in the foreground.
final class PairableHostAdvertiser {
    private var listener: NWListener?
    private var activeRelay: RelayPipe?
    private(set) var publishedPort: UInt16 = 0
    private var rustLoopbackPort: UInt16 = 0

    func publish(
        port: UInt16,
        serviceIdentifier: String,
        name: String,
        model: String,
        authTag: String,
        ver: String,
        minVer: String
    ) {
        stop()
        rustLoopbackPort = port

        var txt = NWTXTRecord()
        txt["name"] = name
        txt["identifier"] = serviceIdentifier
        txt["authTag"] = authTag
        txt["model"] = model
        txt["flags"] = "1"
        txt["ver"] = ver
        txt["minVer"] = minVer

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: serviceIdentifier,
                type: "_remotepairing-pairable-host._tcp",
                domain: "local",
                txtRecord: txt
            )

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let p = listener.port?.rawValue ?? 0
                    self?.publishedPort = p
                    NSLog("[Shift] NWListener ready on port %u (relay → 127.0.0.1:%u)", p, port)
                case .failed(let error):
                    NSLog("[Shift] NWListener failed: %@", String(describing: error))
                case .cancelled:
                    NSLog("[Shift] NWListener cancelled")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                NSLog(
                    "[Shift] NWListener accepted %@",
                    String(describing: connection.endpoint)
                )
                self?.relay(connection)
            }

            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            NSLog("[Shift] NWListener starting; will relay → 127.0.0.1:%u", port)
        } catch {
            NSLog("[Shift] NWListener start failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        activeRelay?.cancel()
        activeRelay = nil
        listener?.cancel()
        listener = nil
    }

    private func relay(_ inbound: NWConnection) {
        activeRelay?.cancel()
        let rustPort = rustLoopbackPort
        guard rustPort > 0, let nwPort = NWEndpoint.Port(rawValue: rustPort) else {
            inbound.cancel()
            return
        }

        let outbound = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: nwPort,
            using: .tcp
        )
        let pipe = RelayPipe(inbound: inbound, outbound: outbound)
        activeRelay = pipe
        pipe.start()
    }
}

/// Bidirectional byte pump between Developer Mode and the Rust loopback listener.
private final class RelayPipe {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue = DispatchQueue(label: "locus.pairable.relay")

    init(inbound: NWConnection, outbound: NWConnection) {
        self.inbound = inbound
        self.outbound = outbound
    }

    func start() {
        inbound.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state { self?.cancel() }
        }
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                NSLog("[Shift] relay connected to Rust loopback")
                self.pump(from: self.inbound, to: self.outbound)
                self.pump(from: self.outbound, to: self.inbound)
            case .failed(let error):
                NSLog("[Shift] relay to Rust failed: %@", String(describing: error))
                self.cancel()
            case .cancelled:
                self.cancel()
            default:
                break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    func cancel() {
        inbound.cancel()
        outbound.cancel()
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("[Shift] relay receive error: %@", String(describing: error))
                self.cancel()
                return
            }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if let sendError {
                        NSLog("[Shift] relay send error: %@", String(describing: sendError))
                        self.cancel()
                        return
                    }
                    if isComplete {
                        self.cancel()
                    } else {
                        self.pump(from: from, to: to)
                    }
                })
            } else if isComplete {
                self.cancel()
            } else {
                self.pump(from: from, to: to)
            }
        }
    }
}

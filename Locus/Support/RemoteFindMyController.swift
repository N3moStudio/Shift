import Combine
import CryptoKit
import Foundation
import Security
import UserNotifications

@MainActor
final class RemoteFindMyController: ObservableObject {
    static let shared = RemoteFindMyController()
    @Published private(set) var paired = false
    @Published private(set) var response: RemoteFindMyResponse?
    @Published private(set) var transportState: RemoteFindMyState = .ready
    @Published private(set) var checkedAt: Date?
    @Published private(set) var checking = false
    @Published private(set) var testingConnection = false
    @Published private(set) var connectionMessage: String?
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "locus.remoteFindMy.enabled")
            if enabled { CompanionClient.shared.enabled = false }
            refreshLifecycle()
        }
    }
    @Published var alerts: Bool {
        didSet {
            UserDefaults.standard.set(alerts, forKey: "locus.remoteFindMy.alerts")
            if !alerts { cancelDeadline() }
            else if monitoring { scheduleDeadline() }
        }
    }
    private weak var session: SpoofSession?
    private var link: RemoteFindMyLink?
    private var task: Task<Void, Never>?
    private var monitoring = false
    private var retry = RemoteFindMyRetryPolicy()
    private var network: URLSession?
    private var connectionTest: URLSession?
    private var ticket = UUID()
    private var began = Date()
    private var sequence = 0
    private var nextCheck = Date.distantPast
    private var lastFresh = Date()
    private var gate = RemoteFindMyAlertGate()
    private var lastLoggedState: RemoteFindMyState?
    private let notificationID = "locus.findmy.checks"
    private let deadlineID = "locus.findmy.deadline"
    private let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ShiftRemoteFindMy", kSecAttrAccount as String: "owner"]

    init() {
        enabled = UserDefaults.standard.bool(forKey: "locus.remoteFindMy.enabled")
        alerts = UserDefaults.standard.object(forKey: "locus.remoteFindMy.alerts") as? Bool ?? true
        var query = key; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
           let value = try? JSONDecoder().decode(RemoteFindMyLink.self, from: data), value.valid {
            link = value; paired = true
        }
        // A new app process never adopts an old monitoring session.
        cancelDeadline()
    }
    func attach(_ session: SpoofSession) { self.session = session }
    var helperWebsite: URL? {
        guard let link, link.valid, link.usesManagedHTTPS else { return nil }
        return URL(string: link.endpoint)
    }
    var state: RemoteFindMyState {
        guard enabled else { return .off }
        guard paired else { return .pairing }
        guard let session, session.remoteCheckSessionRequested else { return .ready }
        guard session.isSpoofing else { return .paused }
        guard response != nil else { return transportState }
        return RemoteFindMyState.evaluate(response, history: session.verification.history, now: Date(), active: session.isSpoofing)
    }
    var reportDate: Date? { response?.report?.locatedAt.map { Date(timeIntervalSince1970: $0) } }
    var activityStatus: RemoteFindMyActivity? {
        guard enabled, paired, session?.remoteCheckSessionRequested == true else { return nil }
        return RemoteFindMyActivity(state: state, reportedAt: reportDate, repliedAt: checkedAt)
    }

    func pair(_ data: Data) throws {
        guard data.count <= 4096, let value = try? JSONDecoder().decode(RemoteFindMyLink.self, from: data), value.valid else { throw RemoteError.invalid }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var added = key; attributes.forEach { added[$0.key] = $0.value }
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw RemoteError.storage }
        } else if result != errSecSuccess { throw RemoteError.storage }
        connectionTest?.invalidateAndCancel()
        stop(); link = value; paired = true; connectionMessage = nil
        enabled = true
        Task { _ = await SessionNotifications.shared.requestPermission() }
    }
    /// Derive the same phone-only key as Render; never retain the admin key.
    static func renderPairing(endpoint: String, helperKey: String) throws -> Data {
        let origin = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...256).contains(helperKey.utf8.count), helperKey.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RemoteError.invalid }
        let token = HMAC<SHA256>.authenticationCode(for: Data("shift-render-phone-v2".utf8), using: SymmetricKey(data: Data(helperKey.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        let value = RemoteFindMyLink(version: 2, kind: "shift-findmy-render", endpoint: origin,
                                    token: token, certificateSHA256: "")
        guard value.valid else { throw RemoteError.invalid }
        return try JSONEncoder().encode(value)
    }
    func testConnection() async {
        guard let link, !testingConnection else { return }
        guard link.usesManagedHTTPS else {
            connectionMessage = "Start a location session and tap Check now to test this server."
            return
        }
        testingConnection = true; connectionMessage = "Connecting… A sleeping server can take a minute."
        defer { testingConnection = false }
        let client = Self.client(link, connectionTest: true)
        connectionTest = client
        defer { client.invalidateAndCancel(); connectionTest = nil }
        do {
            var request = URLRequest(url: URL(string: link.endpoint)!.appendingPathComponent("v1/status"))
            request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
            let (bytes, reply) = try await client.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = reply as? HTTPURLResponse else { throw RemoteError.unavailable }
            guard self.link == link, !Task.isCancelled else { return }
            if http.statusCode == 401 {
                connectionMessage = "Helper key not accepted. Reconnect using the key set on your server."
                return
            }
            if http.statusCode == 404 {
                connectionMessage = "Your helper needs the latest update for this connection test. Existing location checks still work."
                return
            }
            guard http.statusCode == 200 else { throw RemoteError.unavailable }
            var data = Data()
            for try await byte in bytes { guard data.count < 2048 else { throw RemoteError.invalid }; data.append(byte) }
            let status = try JSONDecoder().decode(HelperStatus.self, from: data)
            guard status.version == 1, ["ready", "sign-in", "busy"].contains(status.status) else { throw RemoteError.invalid }
            guard self.link == link, !Task.isCancelled else { return }
            connectionMessage = status.status == "ready" ? "Connected. Apple is signed in. Start a location session to compare reports." :
                status.status == "busy" ? "Connected. Apple sign-in is still finishing in your helper." : "Connected. Open your helper to sign in to Apple and choose your iPhone."
        } catch {
            guard self.link == link, !Task.isCancelled else { return }
            connectionMessage = "Couldn't reach your helper. Check its URL and server status, then try again. A sleeping server may need more time."
        }
    }
    private struct HelperStatus: Decodable { let version: Int; let status: String }
    func unpair() {
        let result = SecItemDelete(key as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { return }
        connectionTest?.invalidateAndCancel(); connectionMessage = nil
        enabled = false; link = nil; paired = false
    }
    func refreshLifecycle() {
        guard enabled, paired, let session, session.remoteCheckSessionRequested else { stop(); return }
        guard !monitoring else {
            if response?.status == "paused", session.isSpoofing, !checking {
                nextCheck = Date()
                tick()
            }
            return
        }
        monitoring = true
        ticket = UUID(); began = Date(); sequence = 0; nextCheck = .distantPast
        retry.reset(); lastLoggedState = nil
        lastFresh = Date(); gate = RemoteFindMyAlertGate(); response = nil; transportState = .waiting
        // Keep connections reusable for this pairing/session. Stop invalidates
        // the client before any new endpoint or access key can be installed.
        if let link { network = Self.client(link) }
        scheduleDeadline()
        tick()
    }
    /// The session monitor owns the clock; no second one-second polling loop.
    func tick() {
        guard monitoring else { return }
        updateWarning()
        guard !checking, task == nil, Date() >= nextCheck else { return }
        let current = ticket
        task = Task { [weak self] in
            guard let self, current == self.ticket, !Task.isCancelled else { return }
            await self.check(current)
            guard current == self.ticket, !Task.isCancelled else { return }
            self.task = nil
            self.updateWarning()
        }
    }
    func checkNow() {
        if !checking { nextCheck = Date() }
        refreshLifecycle()
        tick()
    }
    var nextWakeDate: Date? {
        guard monitoring else { return nil }
        let now = Date()
        var dates = checking || task != nil ? [] : [nextCheck]
        if let response { dates.append(Date(timeIntervalSince1970: response.serverTime + 90)) }
        if let reportDate { dates.append(reportDate.addingTimeInterval(90)) }
        return dates.filter { $0 > now }.min()
    }
    func stop() {
        guard monitoring || task != nil || response != nil else { cancelDeadline(); return }
        let oldID = ticket; let oldLink = link
        monitoring = false
        ticket = UUID(); task?.cancel(); task = nil; network?.invalidateAndCancel(); network = nil
        response = nil; checking = false; checkedAt = nil; transportState = .ready; cancelDeadline()
        session?.remoteCheckDidChange()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID, deadlineID])
        // Best effort deletion; the helper also expires the lease without a reply.
        if let oldLink {
            Task {
                let client = Self.client(oldLink)
                defer { client.invalidateAndCancel() }
                guard let url = URL(string: oldLink.endpoint)?.appendingPathComponent("v1/session/\(oldID.uuidString.lowercased())") else { return }
                var request = URLRequest(url: url); request.httpMethod = "DELETE"
                request.setValue("Bearer \(oldLink.token)", forHTTPHeaderField: "Authorization")
                _ = try? await client.data(for: request)
            }
        }
    }
    private func check(_ current: UUID) async {
        guard let link, let session, let client = network, current == ticket else { return }
        nextCheck = Date().addingTimeInterval(60); checking = true; sequence += 1
        let expected = sequence
        let samples = session.verification.history.filter { $0.confirmedAt >= began }
        let payload = RemoteFindMyRequest(sessionID: current, startedAt: began.timeIntervalSince1970,
            sequence: expected, sentAt: Date().timeIntervalSince1970, active: session.isSpoofing,
            samples: session.isSpoofing ? samples.map(RemoteFindMySample.init) : [])
        defer {
            if current == ticket {
                checking = false
                session.remoteCheckDidChange()
            }
        }
        do {
            guard let url = URL(string: link.endpoint)?.appendingPathComponent("v1/check") else { throw RemoteError.invalid }
            var request = URLRequest(url: url); request.httpMethod = "POST"
            request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            let (bytes, reply) = try await client.bytes(for: request)
            var fullyRead = false
            defer { if !fullyRead { bytes.task.cancel() } }
            guard let http = reply as? HTTPURLResponse else { throw RemoteError.unavailable }
            if [401, 409].contains(http.statusCode) { throw RemoteError.pairing }
            guard http.statusCode == 200 else { throw RemoteError.unavailable }
            var body = Data()
            for try await byte in bytes { guard body.count < 32768 else { throw RemoteError.invalid }; body.append(byte) }
            fullyRead = true
            let value = try JSONDecoder().decode(RemoteFindMyResponse.self, from: body)
            guard value.valid(for: current, sequence: expected, now: Date()) else { throw RemoteError.invalid }
            guard current == ticket, !Task.isCancelled else { return }
            response = value; checkedAt = Date(); transportState = .waiting
            if ["unavailable", "blocked", "sign-in"].contains(value.status) {
                nextCheck = Date().addingTimeInterval(retry.failureDelay())
            } else { retry.reset() }
            DeveloperLogStore.shared.record("remote_findmy_report", ["state": state.rawValue,
                "apple_age_seconds": reportDate.map { String(Int(max(0, Date().timeIntervalSince($0)))) } ?? "missing"])
            if [.match, .different].contains(state) {
                lastFresh = Date(); scheduleDeadline()
            }
        } catch {
            guard current == ticket, !Task.isCancelled else { return }
            response = nil
            transportState = (error as? RemoteError) == .pairing ? .pairing : .unavailable
            nextCheck = Date().addingTimeInterval(retry.failureDelay())
        }
    }
    private func updateWarning() {
        let value = state
        if value != lastLoggedState {
            DeveloperLogStore.shared.record("remote_findmy_state", ["state": value.rawValue])
            lastLoggedState = value
            session?.remoteCheckDidChange()
        }
        guard alerts, let message = value.warning else { return }
        if gate.shouldNotify(value, now: Date(), lastFresh: lastFresh) {
            cancelDeadline()
            notify(id: notificationID, title: value.title, body: message, delay: nil)
        }
    }
    private func scheduleDeadline() {
        guard alerts else { return }
        // Downloading an older matching fix must not buy a new 3-minute window.
        let sourceTime = reportDate ?? began
        let delay = max(1, sourceTime.addingTimeInterval(180).timeIntervalSinceNow)
        notify(id: deadlineID, title: "Find My freshness reminder",
            body: "No fresh Find My report was confirmed before this reminder. Apple may still be showing an older location, or checks may have paused. Open Shift for the latest status.", delay: delay)
    }
    private func cancelDeadline() { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [deadlineID]) }
    private func notify(id: String, title: String, body: String, delay: TimeInterval?) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
            DeveloperLogStore.shared.record("remote_findmy_notification", ["id": id,
                "result": error == nil ? "accepted_by_iOS_not_proof_seen" : "failed"])
        }
    }
    private static func client(_ link: RemoteFindMyLink, connectionTest: Bool = false) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectionTest ? 65 : 12
        config.timeoutIntervalForResource = connectionTest ? 70 : 20
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: RemoteFindMyTrust(link), delegateQueue: nil)
    }
    enum RemoteError: Error, LocalizedError, Equatable {
        case invalid, storage, unavailable, pairing
        var errorDescription: String? {
            switch self {
            case .invalid: return "This isn't a valid ShiftFindMyPairing.json file from a cloud helper."
            case .storage: return "Couldn't save the protected helper key. Unlock your iPhone and retry."
            case .unavailable: return "Cloud helper unavailable."
            case .pairing: return "Reconnect the cloud helper."
            }
        }
    }
}

private final class RemoteFindMyTrust: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let link: RemoteFindMyLink
    init(_ link: RemoteFindMyLink) { self.link = link }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              link.valid, challenge.protectionSpace.host == URL(string: link.endpoint)?.host else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        if link.usesManagedHTTPS {
            // Render renews its certificates. iOS validates the full chain and hostname.
            completionHandler(.performDefaultHandling, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust, let cert = SecTrustGetCertificateAtIndex(trust, 0),
              SHA256.hash(data: SecCertificateCopyData(cert) as Data).map({ String(format: "%02x", $0) }).joined() == link.certificateSHA256.lowercased() else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

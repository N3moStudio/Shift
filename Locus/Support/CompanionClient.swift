import Combine
import CryptoKit
import Foundation
import Security

@MainActor
final class CompanionClient: ObservableObject {
    static let shared = CompanionClient()
    @Published private(set) var reports: [LocationReport] = []
    @Published private(set) var paired = false
    @Published private(set) var fetching = false
    @Published var message: String?
    @Published private(set) var connectedAt: Date?
    @Published var enabled = UserDefaults.standard.bool(forKey: "shift.computerChecks.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "shift.computerChecks.enabled")
            if enabled { RemoteFindMyController.shared.enabled = false; nextCheck = .distantPast; tick() }
            else { cancel() }
            session?.remoteCheckDidChange()
        }
    }
    private weak var session: SpoofSession?
    private var nextCheck = Date.distantPast
    var endpoint: String? { link?.endpoint }
    func attach(_ session: SpoofSession) { self.session = session }
    func tick() {
        guard enabled, paired, session?.remoteCheckSessionRequested == true, !fetching, Date() >= nextCheck else { return }
        nextCheck = Date().addingTimeInterval(60)
        Task { await refresh() }
    }
    var nextWakeDate: Date? {
        enabled && paired && session?.remoteCheckSessionRequested == true && !fetching ? nextCheck : nil
    }
    var activityStatus: RemoteFindMyActivity? {
        guard enabled, paired, let session, session.remoteCheckSessionRequested else { return nil }
        let report = reports.first { $0.provider == "findmy-device" }
        if !reports.isEmpty && report == nil { return nil } // A Life360-only setup has no Find My evidence.
        var state: RemoteFindMyState = .waiting
        if !session.isSpoofing { state = .paused }
        else if connectedAt == nil || message != nil || Date().timeIntervalSince(connectedAt!) > 90 { state = .unavailable }
        else if report?.state == "sign-in" { state = .signIn }
        else if report?.state == "blocked" { state = .blocked }
        else if report?.state == "unavailable" || report == nil { state = .unavailable }
        else {
            switch VerificationResult.evaluate(report, history: session.verification.history, now: Date(), active: true).kind {
            case .match: state = .match
            case .different: state = .different
            case .old: state = .old
            case .unknown: state = .waiting
            }
        }
        return RemoteFindMyActivity(state: state, reportedAt: report?.locatedAt.map { Date(timeIntervalSince1970: $0) }, repliedAt: connectedAt)
    }
    private var link: CompanionLink?
    private var generation = UUID()
    private var network: URLSession?
    private let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "LocusCompanion", kSecAttrAccount as String: "local-pair"]
    init() {
        var query = key; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data,
           let stored = try? JSONDecoder().decode(CompanionLink.self, from: data), stored.valid { link = stored; paired = true }
    }
    func pair(data: Data) throws {
        guard data.count <= 4096, let value = try? JSONDecoder().decode(CompanionLink.self, from: data), value.valid else { throw CompanionError.invalid }
        let encoded = try JSONEncoder().encode(value)
        let attributes = [kSecValueData as String: encoded,
                          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let update = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var added = key; for (k, v) in attributes { added[k] = v }
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw CompanionError.storage }
        } else if update != errSecSuccess { throw CompanionError.storage }
        cancel(); connectedAt = nil; link = value; paired = true; message = "Setup saved. Tap Test connection."
    }
    func unpair() {
        let result = SecItemDelete(key as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { message = CompanionError.storage.localizedDescription; return }
        cancel(); enabled = false; connectedAt = nil; link = nil; paired = false; message = nil
    }
    func cancel() {
        generation = UUID(); network?.invalidateAndCancel(); network = nil
        fetching = false; reports = []; message = nil; connectedAt = nil
    }
    func refresh() async {
        guard let link, !fetching, let base = URL(string: link.endpoint) else { return }
        fetching = true
        nextCheck = Date().addingTimeInterval(60)
        let ticket = generation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let trust = PinnedCompanionDelegate(link: link)
        let client = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        network = client
        defer {
            client.invalidateAndCancel()
            if generation == ticket { fetching = false; network = nil; session?.remoteCheckDidChange() }
        }
        do {
            var request = URLRequest(url: base.appendingPathComponent("reports"))
            request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await client.bytes(for: request, delegate: trust)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw CompanionConnectionIssue.server }
            if let issue = CompanionConnectionIssue.http(http.statusCode) { throw issue }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 32_768 { throw CompanionConnectionIssue.format }
                data.append(byte)
            }
            let payload = try JSONDecoder().decode(CompanionReports.self, from: data)
            guard payload.valid else { throw CompanionConnectionIssue.format }
            guard generation == ticket, !Task.isCancelled else { return }
            reports = payload.reports; connectedAt = Date(); message = reports.isEmpty ? "No services selected on the computer." : nil
        } catch {
            guard generation == ticket else { return }
            reports = []
            let issue = trust.rejectedCertificate ? CompanionConnectionIssue.certificate : CompanionConnectionIssue.transport(error)
            message = issue.localizedDescription
            DeveloperLogStore.shared.record("computer_check_failed", ["reason": issue.rawValue, "code": String((error as NSError).code)])
        }
    }
    enum CompanionError: LocalizedError {
        case invalid, storage, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "This isn't a valid Shift computer setup file. Create a new one on your computer."
            case .storage: return "Couldn't update the protected companion pairing. Unlock your iPhone and try again."
            case .unavailable: return "The companion couldn't provide a report."
            }
        }
    }
}

private final class PinnedCompanionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let link: CompanionLink
    private let lock = NSLock()
    private var rejected = false
    var rejectedCertificate: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
    private func reject() { lock.lock(); rejected = true; lock.unlock() }
    init(link: CompanionLink) { self.link = link }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        verify(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        verify(challenge, completionHandler: completionHandler)
    }
    private func verify(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == URL(string: link.endpoint)?.host,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let data = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == link.certificateSHA256.lowercased() else { reject(); completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

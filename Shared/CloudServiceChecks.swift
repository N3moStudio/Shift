import Foundation

/// Optional addition to v1: existing Apple-only helpers and pairings still work.
struct CloudServiceReport: Decodable {
    let status: String
    let report: LocationReport?
    func valid(provider: String) -> Bool {
        ["match", "different", "waiting", "old", "sign-in", "blocked", "unavailable", "paused"].contains(status) &&
        (report.map { $0.valid && $0.provider == provider } ?? true)
    }
}

extension RemoteFindMyState {
    var life360Title: String {
        switch self {
        case .off: return "Life360 checks off"
        case .ready: return "Life360 ready for your next session"
        case .waiting: return "Waiting for a Life360 report"
        case .match: return "Life360 report matches"
        case .different: return "Life360 report shows somewhere else"
        case .old: return "Life360 location report is old"
        case .signIn: return "Life360 sign-in needed"
        case .blocked: return "Life360 declined the check"
        case .unavailable: return "Life360: no recent check"
        case .paused: return "Life360 checks paused"
        case .pairing: return "Reconnect the cloud helper"
        }
    }
    var life360Warning: String? {
        switch self {
        case .different: return "A recent Life360 report differs from the point Shift sent at that time. Open Shift to review."
        case .signIn: return "Open your helper and reconnect the Life360 observer account. Server restarts clear its sign-in."
        case .blocked: return "Life360 declined or limited access. Review the official app and try later. Checks have paused."
        case .old: return "Life360 has not supplied a fresh location. A new helper reply does not make that location newer."
        case .unavailable: return "No usable Life360 report. Check the helper, observer sign-in, and profile sharing. This does not mean spoofing stopped."
        case .waiting: return "Waiting for a Life360 location that can be compared with this session."
        case .pairing: return "Reconnect your helper using its current key."
        default: return nil
        }
    }
}

enum CloudConnectionIssue: String, Error, LocalizedError {
    case key, session, clock, limited, waking, offline, address, certificate, format, server

    static func http(_ code: Int) -> Self? {
        switch code {
        case 200: return nil
        case 401, 403: return .key
        case 409: return .session
        case 400: return .clock
        case 429: return .limited
        case 502, 503, 504: return .waking
        case 404: return .format
        default: return .server
        }
    }
    static func transport(_ error: Error) -> Self {
        if let issue = error as? Self { return issue }
        if error is DecodingError { return .format }
        switch (error as NSError).code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return .offline
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost: return .waking
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .address
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid: return .certificate
        default: return .server
        }
    }
    var errorDescription: String? {
        switch self {
        case .key: return "Helper key not accepted. Reconnect with the current SHIFT_ADMIN_KEY from your server."
        case .session: return "This check session was replaced. Turn cloud checks off and on to start a new session."
        case .clock: return "The helper rejected the request or its time. Check automatic date and time on your iPhone and server."
        case .limited: return "The helper is limiting requests. Wait a minute before checking again."
        case .waking: return "The helper did not respond in time. A free server may be waking or restarting. Wait about a minute, then tap Test connection."
        case .offline: return "Your iPhone lost its internet connection. Reconnect to Wi-Fi or cellular; checks will retry."
        case .address: return "The helper address could not be found. Check its HTTPS address in Render and reconnect."
        case .certificate: return "The helper’s secure connection could not be verified. Check its certificate and address; do not bypass this check."
        case .format: return "The helper returned an unsupported response. Deploy the latest cloud helper, then test again."
        case .server: return "The helper could not complete this request. Check its server status, then retry."
        }
    }
}

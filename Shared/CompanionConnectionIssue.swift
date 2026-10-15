import Foundation

enum CompanionConnectionIssue: String, Error, LocalizedError {
    case pairing, certificate, network, timeout, localAccess, format, server
    static func http(_ code: Int) -> Self? {
        if code == 200 { return nil }
        return code == 401 || code == 403 ? .pairing : .server
    }
    static func transport(_ error: Error) -> Self {
        if let issue = error as? Self { return issue }
        if error is DecodingError { return .format }
        let code = (error as NSError).code
        guard (error as NSError).domain == NSURLErrorDomain else { return .server }
        switch code {
        case -1001: return .timeout
        case -1022: return .localAccess
        case -1206 ... -1200: return .certificate
        default: return .network
        }
    }
    var errorDescription: String? {
        switch self {
        case .pairing: return "The helper rejected this setup file. Import the current ShiftCompanionPairing.json from the running helper."
        case .certificate: return "The helper’s secure identity could not be verified. Import its current setup file. If this continues, update Shift and the Windows helper."
        case .network: return "Cannot reach the computer. Keep its helper open, connect both devices to the same Wi-Fi, and enable local-network access for Shift or its LiveContainer host."
        case .timeout: return "The computer did not reply in time. Check that it is awake and the helper is still running, then retry."
        case .localAccess: return "iOS blocked the local connection. Update Shift and LiveContainer, then check Local Network access in iPhone Settings."
        case .format: return "The computer sent an incompatible report. Install the latest Shift Windows helper."
        case .server: return "The helper could not complete this request. Check its window and retry."
        }
    }
}

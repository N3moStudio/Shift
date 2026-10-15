import Darwin
import Foundation
import UIKit

enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!

    /// Starts the tunnel, then returns to Shift via `shift://`.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=shift")!

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(detectURL)
    }

    /// Best-effort address hint only. A missing match does not mean disconnected;
    /// another VPN can also match. Never use this to gate a developer command.
    static var hasMatchingInterface: Bool {
        let addresses = ipv4InterfaceAddresses()
        let target = TunnelConfig.targetIP
        if addresses.contains(target) { return true }

        let parts = target.split(separator: ".")
        guard parts.count == 4 else { return false }
        let prefix = parts.dropLast().joined(separator: ".") + "."
        return addresses.contains { $0.hasPrefix(prefix) }
    }

    static func openInstalled() {
        UIApplication.shared.open(enableURL)
    }

    static func openAppStore() {
        UIApplication.shared.open(appStoreURL)
    }

    /// Open LocalDevVPN to connect if installed; otherwise App Store.
    static func openOrInstall() {
        if isInstalled {
            openInstalled()
        } else {
            openAppStore()
        }
    }

    private static func ipv4InterfaceAddresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name).hasPrefix("utun") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(
                    address,
                    nameLen,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    results.append(String(cString: host))
                }
            }
            ptr = interface.ifa_next
        }
        return results
    }
}

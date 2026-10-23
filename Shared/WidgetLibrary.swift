import Foundation

struct LocusShortcut: Equatable {
    enum Kind: String { case place, trip }
    let kind: Kind
    let id: UUID
    var url: URL { URL(string: "shift://\(kind.rawValue)/\(id.uuidString)")! }
    init(kind: Kind, id: UUID) { self.kind = kind; self.id = id }
    init?(url: URL) {
        guard ["shift", "locus"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              let host = url.host, let kind = Kind(rawValue: host),
              url.pathComponents.count == 2, let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        self.init(kind: kind, id: id)
    }
}

struct WidgetLibraryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let kind: String
    var url: URL? { LocusShortcut.Kind(rawValue: kind).map { LocusShortcut(kind: $0, id: id).url } }
}

struct WidgetLibrary: Codable, Equatable {
    static let group = "group.com.n3mostudio.shift"
    static let filename = "WidgetLibrary.json"
    var items: [WidgetLibraryItem]
    var primaryID: UUID?
    var valid: Bool { items.count <= 4 && items.allSatisfy { !$0.title.isEmpty && $0.title.count <= 120 && $0.url != nil } && Set(items.map(\.id)).count == items.count }
    var primary: WidgetLibraryItem? { items.first(where: { $0.id == primaryID }) ?? items.first }

    /// Sideloaders may append a team identifier to the group. Read only our own
    /// embedded profile, then let the OS enforce access to each candidate.
    static func groups(in profile: Data) -> [String] {
        guard profile.count <= 2_000_000,
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups.filter { $0 == group || $0.hasPrefix(group + ".") }.sorted()
    }
    #if os(iOS)
    static let containerURL: URL? = {
        var candidates: [String] = []
        if let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: profile, options: .mappedIfSafe) {
            candidates = groups(in: data)
        }
        for name in candidates + [group] {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name) { return url }
        }
        return nil
    }()
    #endif
}

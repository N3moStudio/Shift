import Foundation

enum SavedPlaceSymbol: String, CaseIterable, Identifiable {
    case pin = "mappin", home = "house.fill", school = "graduationcap.fill"
    case work = "briefcase.fill", gym = "dumbbell.fill", cafe = "cup.and.saucer.fill"
    case park = "leaf.fill", shop = "bag.fill", people = "person.2.fill", star = "star.fill"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pin: return "Pin"; case .home: return "Home"; case .school: return "School"
        case .work: return "Work"; case .gym: return "Gym"; case .cafe: return "Cafe"
        case .park: return "Park"; case .shop: return "Shop"; case .people: return "People"; case .star: return "Star"
        }
    }
}

enum SavedPlaceTint: String, CaseIterable, Identifiable {
    case mint, blue, purple, pink, orange, red
    var id: String { rawValue }
    var title: String { self == .mint ? "Shift accent" : rawValue.capitalized }
}

/// Search only local setting names and aliases. No user data or network requests.
enum SettingsDestination: String, CaseIterable, Identifiable {
    case connection, appearance, activity, notifications, privacy, speeds, shortcuts
    case widgets, recovery, experimental, remoteFindMy, report, diagnostics, about, backup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: return "Connection"; case .appearance: return "Appearance"
        case .activity: return "Live Activities"; case .notifications: return "Notifications"
        case .privacy: return "Privacy & history"; case .speeds: return "Usual speeds"
        case .shortcuts: return "Panel shortcuts"; case .widgets: return "Home Screen widgets"
        case .recovery: return "Trip recovery"; case .experimental: return "Advanced & experimental"
        case .remoteFindMy: return "Find My & Life360"; case .report: return "Report a problem"
        case .diagnostics: return "Diagnostics"; case .about: return "About Shift"; case .backup: return "Files & backups"
        }
    }
    var symbol: String {
        switch self {
        case .connection: return "antenna.radiowaves.left.and.right"; case .appearance: return "circle.lefthalf.filled"
        case .activity: return "platter.filled.top.iphone"; case .notifications: return "bell"
        case .privacy: return "hand.raised"; case .speeds: return "speedometer"
        case .shortcuts: return "slider.horizontal.3"; case .widgets: return "square.grid.2x2"
        case .recovery: return "arrow.counterclockwise"; case .experimental: return "flask"
        case .remoteFindMy: return "icloud"; case .report: return "doc.text.magnifyingglass"
        case .diagnostics: return "waveform.path.ecg"; case .about: return "info.circle"; case .backup: return "externaldrive"
        }
    }
    private var aliases: String {
        switch self {
        case .connection: return "wifi wi-fi vpn localdevvpn pair pairing tunnel retry"
        case .appearance: return "liquid glass panel theme light dark system style glacier afterhours porcelain icon icons logo tinted"
        case .activity: return "lock screen lockscreen dynamic island hide location progress timer"
        case .notifications: return "alert alerts warning warnings reminders sound"
        case .privacy: return "face id passcode app switcher contents recent locations history retention"
        case .speeds: return "walk walking run running bike bicycle ebike e-bike car driving mph km/h kmh kilometers miles units speed"
        case .shortcuts: return "bottom menu buttons controls"
        case .widgets: return "home screen shortcuts favorite favorites saved places routes"
        case .recovery: return "recover restore interrupted route session trip"
        case .experimental: return "find my life360 life 360 companion computer checks verification"
        case .remoteFindMy: return "remote find my experimental apple icloud cloud helper server login findmy life360 cron uptime"
        case .report: return "bug bugs issue issues feedback diagnostics"
        case .diagnostics: return "developer dev log logs timeline recording diagnostics export"
        case .about: return "version build license credits n3mo nemo"
        case .backup: return "back up backup backups restore files transfer data export import gpx pairing helper"
        }
    }
    static func results(for query: String) -> [Self] {
        let terms = normalized(query).split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty else { return [] }
        return allCases.filter { item in
            let text = normalized(item.title + " " + item.aliases)
            return terms.allSatisfy { text.contains($0) }
        }
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

import SwiftUI
import WidgetKit

@MainActor
final class SessionPreferences: ObservableObject {
    static let shared = SessionPreferences()
    @Published var liveActivities: Bool { didSet { save(liveActivities, "liveActivities") } }
    @Published var hideLocation: Bool { didSet { save(hideLocation, "hideLocation") } }
    @Published var hideIslandLocation: Bool { didSet { save(hideIslandLocation, "hideIslandLocation") } }
    @Published var lockScreenProgress: Bool { didSet { save(lockScreenProgress, "lockScreenProgress") } }
    @Published var islandProgress: Bool { didSet { save(islandProgress, "islandProgress") } }
    @Published var islandTimer: Bool { didSet { save(islandTimer, "islandTimer") } }
    @Published var glassPanel: Bool { didSet { save(glassPanel, "glassPanel") } }
    @Published var connectionAlerts: Bool { didSet { save(connectionAlerts, "connectionAlerts") } }
    @Published var connectionCheckSeconds: Int {
        didSet {
            let bounded = SessionTiming.checkSeconds(connectionCheckSeconds)
            if bounded != connectionCheckSeconds { connectionCheckSeconds = bounded }
            defaults.set(bounded, forKey: "shift.connectionCheckSeconds")
        }
    }
    @Published var reminderMinutes: Int { didSet { save(reminderMinutes, "reminderMinutes") } }
    @Published var appearance: String { didSet { save(appearance, "appearance") } }
    @Published var appLockEnabled: Bool { didSet { save(appLockEnabled, "appLockEnabled") } }
    @Published var hideInAppSwitcher: Bool { didSet { save(hideInAppSwitcher, "hideInAppSwitcher") } }
    @Published var saveRecentLocations: Bool { didSet { save(saveRecentLocations, "saveRecentLocations") } }
    @Published var recentHistoryRetention: RecentHistoryRetention { didSet { save(recentHistoryRetention.rawValue, "recentHistoryRetention") } }
    @Published var panelShortcuts: [PanelShortcut] {
        didSet {
            let normalized = PanelShortcut.normalized(panelShortcuts)
            if panelShortcuts != normalized { panelShortcuts = normalized }
            save(normalized.map(\.rawValue), "panelShortcuts")
        }
    }
    @Published var visualStyle: ShiftVisualStyle {
        didSet {
            guard visualStyle != oldValue else { return }
            defaults.set(visualStyle.rawValue, forKey: ShiftAppearanceSelection.styleKey)
            publishAppearance()
        }
    }
    @Published private(set) var iconSelection: ShiftIconSelection
    private let defaults: UserDefaults

    func confirmIcon(_ selection: ShiftIconSelection) {
        guard iconSelection != selection else { return }
        iconSelection = selection
        defaults.set(selection.id, forKey: ShiftAppearanceSelection.iconKey)
        publishAppearance()
    }

    func publishAppearance() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let container = WidgetLibrary.containerURL,
              let data = try? encoder.encode(ShiftAppearanceSelection(style: visualStyle, icon: iconSelection)) else { return }
        let destination = container.appendingPathComponent("ShiftAppearance.json")
        guard (try? Data(contentsOf: destination)) != data else { return }
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            WidgetCenter.shared.reloadAllTimelines()
        } catch { /* In-app choices still persist when shared widget storage is unavailable. */ }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let branding = ShiftAppearanceSelection(defaults: defaults)
        visualStyle = branding.style
        iconSelection = branding.icon
        connectionCheckSeconds = SessionTiming.checkSeconds(defaults.object(forKey: "shift.connectionCheckSeconds") as? Int ?? SessionTiming.defaultCheckSeconds)
        panelShortcuts = PanelShortcut.normalized((defaults.stringArray(forKey: "locus.panelShortcuts") ?? []).compactMap(PanelShortcut.init(rawValue:)))
        defaults.register(defaults: [
            "locus.liveActivities": true, "locus.hideLocation": false,
            "locus.hideIslandLocation": false,
            "locus.connectionAlerts": true, "locus.reminderMinutes": 0,
            "locus.appearance": "system", "locus.lockScreenProgress": true,
            "locus.islandProgress": true, "locus.islandTimer": true, "locus.glassPanel": true,
            "locus.appLockEnabled": false, "locus.hideInAppSwitcher": false,
            "locus.saveRecentLocations": true, "locus.recentHistoryRetention": RecentHistoryRetention.forever.rawValue
        ])
        liveActivities = defaults.bool(forKey: "locus.liveActivities")
        hideLocation = defaults.bool(forKey: "locus.hideLocation")
        hideIslandLocation = defaults.bool(forKey: "locus.hideIslandLocation")
        lockScreenProgress = defaults.bool(forKey: "locus.lockScreenProgress")
        islandProgress = defaults.bool(forKey: "locus.islandProgress")
        islandTimer = defaults.bool(forKey: "locus.islandTimer")
        glassPanel = defaults.bool(forKey: "locus.glassPanel")
        connectionAlerts = defaults.bool(forKey: "locus.connectionAlerts")
        reminderMinutes = defaults.integer(forKey: "locus.reminderMinutes")
        appearance = defaults.string(forKey: "locus.appearance") ?? "system"
        appLockEnabled = defaults.bool(forKey: "locus.appLockEnabled")
        hideInAppSwitcher = defaults.bool(forKey: "locus.hideInAppSwitcher")
        saveRecentLocations = defaults.bool(forKey: "locus.saveRecentLocations")
        recentHistoryRetention = RecentHistoryRetention(rawValue: defaults.string(forKey: "locus.recentHistoryRetention") ?? "") ?? .forever
    }

    var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }

    private func save(_ value: Any, _ key: String) {
        DeveloperLogStore.shared.record("preference_changed", ["preference": key, "value": String(describing: value)])
        defaults.set(value, forKey: "locus.\(key)")
    }
}

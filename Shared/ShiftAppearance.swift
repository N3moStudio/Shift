import Foundation

/// Interface style and Home Screen artwork deliberately have separate storage.
enum ShiftVisualStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case glacier, afterhours, porcelain
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .glacier: return "Ice blue & silver"
        case .afterhours: return "Ink & violet"
        case .porcelain: return "Chalk & graphite"
        }
    }
    var cornerRadius: Double { self == .afterhours ? 28 : self == .porcelain ? 13 : 20 }
    var heading: String {
        switch self {
        case .glacier: return "Make your\nnext move."
        case .afterhours: return "One connection.\nYour next move."
        case .porcelain: return "Ready.\nSet. Shift."
        }
    }
    init(storedValue: String?) { self = storedValue.flatMap(Self.init(rawValue:)) ?? .glacier }

    enum Ink: CaseIterable { case accent, onAccent, secondary, canvas, surface, text, muted }
    func hex(_ ink: Ink, dark: Bool) -> Int {
        let light: [Int], night: [Int]
        switch self {
        case .glacier:
            light = [0x255BA4, 0xFFFFFF, 0x3D6594, 0xF2F6FB, 0xFFFFFF, 0x17283B, 0x53667D]
            night = [0xB5D9FF, 0x10243D, 0xACCCF0, 0x111923, 0x1B2633, 0xEFF5FC, 0xA7BACF]
        case .afterhours:
            light = [0x7142A9, 0xFFFFFF, 0x67528F, 0xF4F1FA, 0xFFFFFF, 0x252037, 0x665879]
            night = [0xD1B4FF, 0x271440, 0xBFB0E4, 0x12101B, 0x211D2F, 0xF4EFFF, 0xB8ACCB]
        case .porcelain:
            light = [0x323B3F, 0xFFFFFF, 0x526777, 0xF6F5F2, 0xFFFFFF, 0x202221, 0x60635D]
            night = [0xDBE4E9, 0x20272A, 0xB7C7D1, 0x171715, 0x242421, 0xF3F3EB, 0xB9BCB0]
        }
        let index: Int
        switch ink { case .accent: index = 0; case .onAccent: index = 1; case .secondary: index = 2
        case .canvas: index = 3; case .surface: index = 4; case .text: index = 5; case .muted: index = 6 }
        return (dark ? night : light)[index]
    }
}

enum ShiftIconDesign: String, CaseIterable, Codable, Identifiable, Sendable {
    case glacier, afterhours, porcelain
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ShiftIconFinish: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard, dark, tinted
    var id: String { rawValue }
    var title: String { self == .standard ? "Default" : rawValue.capitalized }
}

struct ShiftIconSelection: Codable, Equatable, Hashable, Identifiable, Sendable {
    var design: ShiftIconDesign = .glacier
    var finish: ShiftIconFinish = .standard
    var id: String { design.rawValue + "." + finish.rawValue }
    var assetName: String {
        if self == Self() { return "AppIcon" }
        return "AppIcon" + design.title + (finish == .standard ? "" : finish.title)
    }
    var alternateName: String? { self == Self() ? nil : assetName }
    var previewName: String { "ShiftIcon-" + design.title + "-" + finish.title }
    var title: String { design.title + " · " + finish.title }
    static var all: [Self] {
        ShiftIconDesign.allCases.flatMap { design in ShiftIconFinish.allCases.map { Self(design: design, finish: $0) } }
    }
    static func installed(named name: String?) -> Self? {
        guard let name else { return Self() }
        return all.first { $0.alternateName == name }
    }
}

struct ShiftAppearanceSelection: Codable, Equatable, Sendable {
    var style: ShiftVisualStyle = .glacier
    var icon: ShiftIconSelection = .init()
    static let styleKey = "shift.visualStyle"
    static let iconKey = "shift.appIcon"
    init(style: ShiftVisualStyle = .glacier, icon: ShiftIconSelection = .init()) {
        self.style = style; self.icon = icon
    }
    init(defaults: UserDefaults) {
        style = ShiftVisualStyle(storedValue: defaults.string(forKey: Self.styleKey))
        icon = defaults.string(forKey: Self.iconKey).flatMap { value in ShiftIconSelection.all.first { $0.id == value } } ?? .init()
    }
}

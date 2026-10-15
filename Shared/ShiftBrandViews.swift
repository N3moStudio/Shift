import SwiftUI
import UIKit

struct ShiftStyleTrait: UITraitDefinition {
    static let defaultValue = ShiftVisualStyle.glacier.rawValue
    static let affectsColorAppearance = true
}
private struct ShiftVisualStyleKey: EnvironmentKey { static let defaultValue = ShiftVisualStyle.glacier }
extension ShiftVisualStyleKey: UITraitBridgedEnvironmentKey {
    static func read(from traits: UITraitCollection) -> ShiftVisualStyle {
        ShiftVisualStyle(storedValue: traits[ShiftStyleTrait.self])
    }
    static func write(to traits: inout UIMutableTraits, value: ShiftVisualStyle) {
        traits[ShiftStyleTrait.self] = value.rawValue
    }
}
private struct ShiftIconDesignKey: EnvironmentKey { static let defaultValue = ShiftIconDesign.glacier }
extension EnvironmentValues {
    var shiftVisualStyle: ShiftVisualStyle {
        get { self[ShiftVisualStyleKey.self] }
        set { self[ShiftVisualStyleKey.self] = newValue }
    }
    var shiftIconDesign: ShiftIconDesign {
        get { self[ShiftIconDesignKey.self] }
        set { self[ShiftIconDesignKey.self] = newValue }
    }
}

/// Monochrome counterparts of the independently selectable app icons.
struct ShiftMark: Shape {
    @Environment(\.shiftIconDesign) private var inheritedDesign
    var design: ShiftIconDesign?
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch design ?? inheritedDesign {
        case .glacier:
            p.move(to: CGPoint(x: 3, y: 11)); p.addLine(to: CGPoint(x: 22, y: 2))
            p.addLine(to: CGPoint(x: 13, y: 21)); p.addLine(to: CGPoint(x: 11, y: 13)); p.closeSubpath()
        case .afterhours:
            let orbit = Path(ellipseIn: CGRect(x: 3, y: 7, width: 18, height: 10))
            p.addPath(orbit, transform: CGAffineTransform(translationX: 12, y: 12).rotated(by: -.pi / 4).translatedBy(x: -12, y: -12))
            p.addEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6))
            p.addEllipse(in: CGRect(x: 3, y: 3, width: 3, height: 3))
            p.addEllipse(in: CGRect(x: 18, y: 18, width: 3, height: 3))
        case .porcelain:
            p.move(to: CGPoint(x: 6, y: 18)); p.addLine(to: CGPoint(x: 18, y: 6))
            p.move(to: CGPoint(x: 8, y: 6)); p.addLine(to: CGPoint(x: 18, y: 6)); p.addLine(to: CGPoint(x: 18, y: 16))
        }
        p = p.strokedPath(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        let scale = min(rect.width, rect.height) / 26
        return p.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - scale * 12, y: rect.midY - scale * 12)))
    }
}

/// Native dynamic colors follow the window trait without recreating the map.
enum ShiftPalette {
    static let accent = color(.accent)
    static let onAccent = color(.onAccent)
    static let secondary = color(.secondary)
    static let canvas = color(.canvas)
    static let surface = color(.surface)
    static let good = adaptive(0x237447, 0x83D7A2)
    static let warning = adaptive(0x8D5100, 0xF5C36B)
    static let danger = adaptive(0xB52243, 0xFF9AAD)
    static let activityBackground = color(.canvas, dark: true)
    static func color(_ ink: ShiftVisualStyle.Ink, style: ShiftVisualStyle? = nil, dark: Bool? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let selected = style ?? ShiftVisualStyle(storedValue: traits[ShiftStyleTrait.self])
            return uiColor(selected.hex(ink, dark: dark ?? (traits.userInterfaceStyle == .dark)))
        })
    }
    private static func uiColor(_ hex: Int) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private static func adaptive(_ light: Int, _ dark: Int) -> Color {
        Color(uiColor: UIColor { uiColor($0.userInterfaceStyle == .dark ? dark : light) })
    }
}

struct ShiftSignature: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("by").foregroundStyle(.secondary)
            Text("N3mo").fontWeight(.semibold).kerning(-0.4)
            Text("Studio").foregroundStyle(.secondary)
        }.font(.caption).accessibilityLabel("by Nemo Studio")
    }
}
struct ShiftWidgetBrand: View {
    var design: ShiftIconDesign?
    var body: some View {
        HStack(spacing: 7) {
            ShiftMark(design: design).fill(.primary).frame(width: 18, height: 18).accessibilityHidden(true)
            Text("Shift").font(.subheadline.weight(.semibold))
        }.accessibilityElement(children: .combine)
    }
}
enum ShiftWidgetAppearance {
    static func read() -> ShiftAppearanceSelection {
        guard let folder = WidgetLibrary.containerURL,
              let data = try? Data(contentsOf: folder.appendingPathComponent("ShiftAppearance.json")), data.count <= 4096,
              let appearance = try? JSONDecoder().decode(ShiftAppearanceSelection.self, from: data) else {
            return ShiftAppearanceSelection()
        }
        return appearance
    }
}

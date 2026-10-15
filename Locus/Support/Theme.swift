import SwiftUI

enum LocusTheme {
    static let accent = ShiftPalette.accent
    static let onAccent = ShiftPalette.onAccent
    static let accentSecondary = ShiftPalette.secondary
    static let danger = ShiftPalette.danger
    static let panelStroke = Color.primary.opacity(0.12)
    static let statusGood = ShiftPalette.good
    static let statusWarn = ShiftPalette.warning
    static let statusBad = ShiftPalette.danger
}

enum LocusGlassStyle {
    case regular
    case clear
    case interactive
}

/// Liquid Glass on iOS 26+; material fallback earlier.
struct LocusGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @EnvironmentObject private var session: SpoofSession
    var style: LocusGlassStyle
    var shape: S
    var tint: Color?
    var allowInLowPower = true

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased || (session.lowPower && !allowInLowPower) {
            content
                .background(shape.fill(Color(uiColor: .secondarySystemBackground)))
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .contentShape(shape)
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(glass, in: shape)
                // Glass draws outside the layout bounds; expand hit-testing to match.
                .contentShape(shape)
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint.opacity(0.55))
                    }
                }
                .overlay(shape.stroke(LocusTheme.panelStroke, lineWidth: 1))
                .contentShape(shape)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var g: Glass = style == .clear ? .clear : .regular
        if style == .interactive { g = g.interactive() }
        if let tint { g = g.tint(tint) }
        return g
    }
}

extension View {
    func locusGlass<S: Shape>(
        _ style: LocusGlassStyle = .regular,
        tint: Color? = nil,
        allowInLowPower: Bool = true,
        in shape: S
    ) -> some View {
        modifier(LocusGlassModifier(style: style, shape: shape, tint: tint, allowInLowPower: allowInLowPower))
    }

    func locusGlass(_ style: LocusGlassStyle = .regular, tint: Color? = nil) -> some View {
        locusGlass(style, tint: tint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

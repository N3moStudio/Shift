import SwiftUI

struct ShiftCanvas: View {
    @Environment(\.shiftVisualStyle) private var style
    var body: some View { ShiftPalette.color(.canvas, style: style).ignoresSafeArea() }
}

struct ShiftScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { ShiftCanvas() }
            .listStyle(.insetGrouped)
            .listRowSpacing(8)
            .listSectionSpacing(20)
            .environment(\.defaultMinListRowHeight, 52)
    }
}

struct ShiftScreenHeading: View {
    let eyebrow: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ShiftMark().fill(LocusTheme.accent.gradient)
                .frame(width: 40, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow.uppercased()).font(.footnote.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-0.9)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 10)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}

struct ShiftRowIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.body.weight(.medium))
            .foregroundStyle(LocusTheme.accent)
            .frame(width: 38, height: 38)
            .background(LocusTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

struct ShiftActionStyle: ButtonStyle {
    @Environment(\.shiftVisualStyle) private var style
    enum Kind: Equatable { case primary, secondary, destructive }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var foreground: Color { kind == .primary ? LocusTheme.onAccent : kind == .destructive ? LocusTheme.danger : .primary }
    private var background: Color { kind == .primary ? LocusTheme.accent : kind == .destructive ? LocusTheme.danger.opacity(0.09) : Color.primary.opacity(0.07) }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 13).frame(minHeight: 48)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: style.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.40)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: configuration.isPressed)
    }
}

extension View {
    func shiftScreen() -> some View { modifier(ShiftScreen()) }
}

// Content uses opaque surfaces; glass is reserved for floating map controls.
struct ShiftSettingsCanvas: View {
    var body: some View { ShiftCanvas().allowsHitTesting(false).accessibilityHidden(true) }
}

struct ShiftSettingsScreen: ViewModifier {
    @Environment(\.shiftVisualStyle) private var style
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { ShiftSettingsCanvas() }
            .listStyle(.insetGrouped)
            .listRowSpacing(style == .afterhours ? 6 : 0)
            .listSectionSpacing(style == .porcelain ? 28 : 24)
            .environment(\.defaultMinListRowHeight, 56)
            .tint(LocusTheme.accent)
    }
}

private struct ShiftSettingsRowSurface: View {
    @Environment(\.shiftVisualStyle) private var style
    var body: some View { ShiftPalette.color(style == .porcelain ? .canvas : .surface, style: style) }
}

extension View {
    func shiftSettingsScreen() -> some View { modifier(ShiftSettingsScreen()) }
    func shiftSettingsRows() -> some View {
        listRowBackground(ShiftSettingsRowSurface())
            .listRowSeparatorTint(Color.primary.opacity(0.10))
    }
}

struct ShiftSettingsCard<Content: View>: View {
    @Environment(\.shiftVisualStyle) private var style
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShiftPalette.color(.surface, style: style), in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
    }
}

struct ShiftSettingsIcon: View {
    let symbol: String
    var color: Color = LocusTheme.accent
    var body: some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.opacity(0.10))
            }
            .overlay { RoundedRectangle(cornerRadius: 13).stroke(color.opacity(0.12), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

struct ShiftSettingsPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ShiftSettingsLink<Destination: View>: View {
    let title: String
    let symbol: String
    var color: Color = LocusTheme.accent
    @ViewBuilder var destination: () -> Destination
    var body: some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 13) {
                ShiftSettingsIcon(symbol: symbol, color: color)
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(ShiftSettingsPressStyle())
    }
}

struct ShiftSettingsDivider: View {
    var body: some View { Divider().overlay(Color.primary.opacity(0.03)).padding(.leading, 67).padding(.trailing, 16) }
}

struct ShiftSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 16).accessibilityAddTraits(.isHeader)
            ShiftSettingsCard { VStack(spacing: 0) { content() } }
        }
    }
}

struct ShiftAcknowledgmentsView: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "OpenSourceNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled notices could not be opened. The full copyright and license notices are also included with the source."
        }
        return text
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShiftSignature()
                Text("Built on open source").font(.title2.weight(.bold))
                Text(notices).font(.footnote).textSelection(.enabled)
            }.frame(maxWidth: 700, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        }.background { ShiftCanvas() }
            .loggedNavigationTitle("Acknowledgments").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ShiftEditorEmbeddedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var shiftEditorEmbedded: Bool {
        get { self[ShiftEditorEmbeddedKey.self] }
        set { self[ShiftEditorEmbeddedKey.self] = newValue }
    }
}

/// Editors can be pushed in a route workflow or opened independently in Library.
struct ShiftEditorContainer<Content: View>: View {
    @Environment(\.shiftEditorEmbedded) private var embedded
    @ViewBuilder var content: () -> Content
    var body: some View {
        if embedded { content().navigationBarBackButtonHidden(true) }
        else { NavigationStack { content().environment(\.shiftEditorEmbedded, true) } }
    }
}

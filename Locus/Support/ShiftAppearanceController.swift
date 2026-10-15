import SwiftUI
import UIKit
import WidgetKit

/// A trait change updates dynamic colors without replacing the map or its state.
struct ShiftAppearanceAnchor: UIViewRepresentable {
    let style: ShiftVisualStyle
    func makeUIView(context: Context) -> Anchor { Anchor(style: style) }
    func updateUIView(_ view: Anchor, context: Context) { view.style = style; view.apply() }
    final class Anchor: UIView {
        var style: ShiftVisualStyle
        init(style: ShiftVisualStyle) { self.style = style; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() { super.didMoveToWindow(); apply() }
        func apply() {
            // traitCollection includes the inherited/default style. Reading an
            // unset traitOverrides entry raises an Objective-C exception on first launch.
            guard let window, window.traitCollection[ShiftStyleTrait.self] != style.rawValue else { return }
            window.traitOverrides[ShiftStyleTrait.self] = style.rawValue
        }
    }
}

@MainActor
final class ShiftIconController: ObservableObject {
    static let shared = ShiftIconController()
    @Published private(set) var selected = ShiftIconSelection()
    @Published private(set) var changing = false
    @Published var error: String?
    var supported: Bool { UIApplication.shared.supportsAlternateIcons }

    func refresh() {
        guard !changing else { return }
        guard let actual = ShiftIconSelection.installed(named: UIApplication.shared.alternateIconName) else {
            error = "This installation uses an unrecognized icon. Choose a Shift icon to replace it."
            return
        }
        selected = actual
        SessionPreferences.shared.confirmIcon(actual)
    }

    func choose(_ choice: ShiftIconSelection) {
        guard !changing else { return }
        guard supported else { error = "This installation does not support changing the Home Screen icon."; return }
        guard UIApplication.shared.alternateIconName != choice.alternateName else { refresh(); return }
        changing = true; error = nil
        UIApplication.shared.setAlternateIconName(choice.alternateName) { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                self.changing = false
                guard failure == nil, UIApplication.shared.alternateIconName == choice.alternateName else {
                    self.error = "iOS couldn’t change the icon. Your previous icon is still selected. Try again while Shift is open."
                    self.refresh()
                    return
                }
                self.selected = choice
                SessionPreferences.shared.confirmIcon(choice)
            }
        }
    }
}

struct ShiftAppIconPreview: View {
    let selection: ShiftIconSelection
    var size: CGFloat = 64
    var body: some View {
        Group {
            if let image = UIImage(named: selection.previewName) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
            } else { ShiftMark(design: selection.design).fill(LocusTheme.accent).padding(10) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
        .accessibilityHidden(true)
    }
}

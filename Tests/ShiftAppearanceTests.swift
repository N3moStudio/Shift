import XCTest
@testable import SessionPresentation

final class ShiftAppearanceTests: XCTestCase {
    func testEveryIconResolvesFromItsInstalledName() {
        XCTAssertEqual(ShiftIconSelection.all.count, 9)
        XCTAssertEqual(Set(ShiftIconSelection.all.map(\.assetName)).count, 9)
        XCTAssertEqual(ShiftIconSelection.all.filter { $0.alternateName == nil }, [ShiftIconSelection()])
        for choice in ShiftIconSelection.all {
            XCTAssertEqual(ShiftIconSelection.installed(named: choice.alternateName), choice)
        }
        XCTAssertNil(ShiftIconSelection.installed(named: "unknown"))
    }
    func testChangingStyleAndIconRemainIndependentAcrossReloads() {
        let suite = "appearance-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("porcelain.dark", forKey: ShiftAppearanceSelection.iconKey)
        for style in ShiftVisualStyle.allCases {
            defaults.set(style.rawValue, forKey: ShiftAppearanceSelection.styleKey)
            let value = ShiftAppearanceSelection(defaults: defaults)
            XCTAssertEqual(value.style, style)
            XCTAssertEqual(value.icon, .init(design: .porcelain, finish: .dark))
        }
        for choice in ShiftIconSelection.all {
            defaults.set(choice.id, forKey: ShiftAppearanceSelection.iconKey)
            let value = ShiftAppearanceSelection(defaults: defaults)
            XCTAssertEqual(value.icon, choice)
            XCTAssertEqual(value.style, .porcelain)
        }
    }
    func testMissingOrInvalidChoicesRecoverWithoutChangingOtherPreferences() {
        let suite = "appearance-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3, forKey: "shift.connectionCheckSeconds")
        defaults.set("missing-style", forKey: ShiftAppearanceSelection.styleKey)
        defaults.set("missing-icon", forKey: ShiftAppearanceSelection.iconKey)
        XCTAssertEqual(ShiftAppearanceSelection(defaults: defaults), ShiftAppearanceSelection())
        XCTAssertEqual(defaults.integer(forKey: "shift.connectionCheckSeconds"), 3)
    }
    func testWidgetSnapshotPreservesMixedChoice() throws {
        let value = ShiftAppearanceSelection(style: .afterhours, icon: .init(design: .glacier, finish: .tinted))
        XCTAssertEqual(try JSONDecoder().decode(ShiftAppearanceSelection.self, from: JSONEncoder().encode(value)), value)
    }
    func testOlderActivityStillDecodesAndUsesGlacierFallback() throws {
        let old = SessionSnapshot(phase: .active, startedAt: Date(timeIntervalSince1970: 100), lastConfirmedAt: nil,
                                  expiresAt: nil, place: nil, lowPower: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "visualStyle")
        object.removeValue(forKey: "iconDesign")
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.visualStyle)
        XCTAssertNil(decoded.iconDesign)
        XCTAssertEqual(ShiftVisualStyle(storedValue: decoded.visualStyle), .glacier)
        XCTAssertEqual(decoded.phase, .active)
    }
    func testTextAndActionsMeetContrastInEveryPalette() {
        for style in ShiftVisualStyle.allCases {
            for dark in [false, true] {
                for background in [ShiftVisualStyle.Ink.canvas, .surface] {
                    for foreground in [ShiftVisualStyle.Ink.text, .muted, .accent, .secondary] {
                        XCTAssertGreaterThanOrEqual(contrast(style.hex(foreground, dark: dark), style.hex(background, dark: dark)), 4.5, "\(style) \(dark) \(foreground) on \(background)")
                    }
                }
                XCTAssertGreaterThanOrEqual(contrast(style.hex(.onAccent, dark: dark), style.hex(.accent, dark: dark)), 4.5)
            }
        }
    }
    private func contrast(_ a: Int, _ b: Int) -> Double {
        func luminance(_ hex: Int) -> Double {
            let rgb = [16,8,0].map { Double((hex >> $0) & 255) / 255 }
                .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x,y) + 0.05) / (min(x,y) + 0.05)
    }
}

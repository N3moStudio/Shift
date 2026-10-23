import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var preferences: SessionPreferences
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        List {
            Section {
                ForEach(ShiftVisualStyle.allCases) { style in
                    Button { preferences.visualStyle = style } label: {
                        HStack(spacing: 14) {
                            StyleSwatch(style: style)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(style.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text(style.detail).font(.subheadline).foregroundStyle(.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if preferences.visualStyle == style { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(LocusTheme.accent) }
                        }.frame(minHeight: 60).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title + ", " + style.detail)
                    .accessibilityAddTraits(preferences.visualStyle == style ? [.isSelected] : [])
                }
            } header: { Text("Interface Style") } footer: { Text("Changes the interface. Your app icon stays the same.") }.shiftSettingsRows()
            Section("Appearance") {
                if typeSize.isAccessibilitySize { appearancePicker.pickerStyle(.menu) }
                else { appearancePicker.pickerStyle(.segmented).padding(.vertical, 6) }
            }.shiftSettingsRows()
            Section {
                NavigationLink {
                    AppIconSettingsView()
                } label: {
                    HStack(spacing: 14) {
                        ShiftAppIconPreview(selection: preferences.iconSelection, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Choose App Icon").foregroundStyle(.primary)
                            Text(preferences.iconSelection.title).font(.subheadline).foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 5)
                }
            } header: { Text("App Icon") } footer: { Text("Mix any icon with any interface style.") }.shiftSettingsRows()
            Section {
                Toggle("Liquid Glass Map Controls", isOn: $preferences.glassPanel)
            } footer: { Text("Applies to the map’s control panel. Navigation follows your iOS appearance and accessibility settings.") }.shiftSettingsRows()
        }
        .shiftSettingsScreen().loggedNavigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }
    private var appearancePicker: some View {
        Picker("Appearance", selection: $preferences.appearance) {
            Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
        }.frame(minHeight: 44)
    }
}

private struct StyleSwatch: View {
    let style: ShiftVisualStyle
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(ShiftPalette.color(.accent, style: style)).frame(width: 28, height: 5)
            Capsule().fill(ShiftPalette.color(.muted, style: style).opacity(0.55)).frame(width: 35, height: 3)
            Capsule().fill(ShiftPalette.color(.accent, style: style).opacity(0.20)).frame(height: 16)
        }.padding(9).frame(width: 55, height: 55)
            .background(ShiftPalette.color(.canvas, style: style), in: RoundedRectangle(cornerRadius: style.cornerRadius * 0.5))
            .overlay { RoundedRectangle(cornerRadius: style.cornerRadius * 0.5).stroke(Color.primary.opacity(0.14), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

struct AppIconSettingsView: View {
    @StateObject private var icons = ShiftIconController.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        List {
            Section {
                HStack(spacing: 15) {
                    ShiftAppIconPreview(selection: icons.selected, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(icons.changing ? "Changing Icon…" : "Current Icon").font(.headline)
                        Text(icons.selected.title).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ProgressView().opacity(icons.changing ? 1 : 0)
                        .accessibilityHidden(!icons.changing)
                        .accessibilityLabel("Changing app icon")
                }.padding(.vertical, 5)
            } footer: { Text("Independent of your interface style. Your Home Screen appearance can also tint icons.") }.shiftSettingsRows()
            ForEach(ShiftIconDesign.allCases) { design in
                Section(design.title) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 125 : 82), spacing: 10)], spacing: 16) {
                        ForEach(ShiftIconFinish.allCases) { finish in
                            let choice = ShiftIconSelection(design: design, finish: finish)
                            Button { icons.choose(choice) } label: {
                                VStack(spacing: 9) {
                                    ShiftAppIconPreview(selection: choice)
                                        .padding(5)
                                        .overlay { RoundedRectangle(cornerRadius: 20).stroke(choice == icons.selected ? LocusTheme.accent : .clear, lineWidth: 2) }
                                    Text(finish.title).font(.subheadline).foregroundStyle(.primary)
                                    ZStack {
                                        Image(systemName: choice == icons.selected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(choice == icons.selected ? LocusTheme.accent : .secondary)
                                            .opacity(icons.pending == choice ? 0 : 1)
                                        if icons.pending == choice { ProgressView().controlSize(.small) }
                                    }.frame(height: 20)
                                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: icons.selected)
                                }.frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(!icons.supported)
                            .accessibilityLabel(choice.title)
                            .accessibilityValue(icons.pending == choice ? "Changing icon" : choice == icons.selected ? "Selected" : "")
                            .accessibilityAddTraits(choice == icons.selected ? [.isSelected] : [])
                        }
                    }.padding(.vertical, 4)
                }.shiftSettingsRows()
            }
            if !icons.supported {
                Section { Text("Icon changes aren’t available in this installation.").font(.subheadline).foregroundStyle(.secondary) }.shiftSettingsRows()
            }
        }
        .shiftSettingsScreen().loggedNavigationTitle("App Icon").navigationBarTitleDisplayMode(.inline)
        .onAppear { icons.refresh() }
        .alert("Couldn’t Change Icon", isPresented: Binding(get: { icons.error != nil }, set: { if !$0 { icons.error = nil } })) {
            Button("OK", role: .cancel) { icons.error = nil }
        } message: { Text(icons.error ?? "Try again while Shift is open.") }
    }
}

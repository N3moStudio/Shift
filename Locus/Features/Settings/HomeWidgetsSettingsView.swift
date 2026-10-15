import SwiftUI

struct HomeWidgetsSettingsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var library: TripLibrary
    @State private var selected: [String] = []
    @State private var primary = ""
    @State private var message: String?
    private var choices: [WidgetLibraryItem] { HomeWidgetPublisher.choices(places: session.favorites, trips: library.trips) }
    var body: some View {
        List {
            Section {
                SettingsHelp(title: "Add a widget", lines: [
                    "Hold an empty spot on your Home Screen → Edit → Add Widget → Shift.",
                    "Choose Favorite shortcut or Saved shortcuts. Tapping opens Shift; you still choose Teleport or Start route.",
                    "The medium widget shows 2 shortcuts; the large one shows 4. Some signing setups cannot share widget data; any error appears here."
                ])
            }.shiftSettingsRows()
            if let message { Section { Text(message).foregroundStyle(LocusTheme.statusWarn) }.shiftSettingsRows() }
            Section("Favorite shortcut") {
                Picker("Show", selection: $primary) {
                    Text("First selected item").tag("")
                    ForEach(choices.filter { selected.contains($0.id.uuidString) }) { Text($0.title).tag($0.id.uuidString) }
                }
            }.shiftSettingsRows()
            Section {
                if choices.isEmpty { Text("Save a place or trip first.").foregroundStyle(.secondary) }
                ForEach(choices) { item in
                    Toggle(item.title, isOn: Binding(get: { selected.contains(item.id.uuidString) }, set: { enabled in
                        if enabled { if selected.count < 4 { selected.append(item.id.uuidString) } }
                        else { selected.removeAll { $0 == item.id.uuidString }; if primary == item.id.uuidString { primary = "" } }
                    })).disabled(selected.count >= 4 && !selected.contains(item.id.uuidString))
                }
            } header: { Text("Up to 4 saved shortcuts") } footer: {
                Text("Selected names are visible on your Home Screen.")
            }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("Home Screen widgets").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selected = UserDefaults.standard.stringArray(forKey: "locus.widget.selected") ?? Array(choices.prefix(4).map { $0.id.uuidString })
            selected = selected.filter { id in choices.contains { $0.id.uuidString == id } }
            primary = UserDefaults.standard.string(forKey: "locus.widget.primary") ?? ""
            save()
        }
        .onChange(of: selected) { _, _ in save() }.onChange(of: primary) { _, _ in save() }
    }
    private func save() {
        UserDefaults.standard.set(selected, forKey: "locus.widget.selected")
        UserDefaults.standard.set(primary, forKey: "locus.widget.primary")
        message = HomeWidgetPublisher.publish(places: session.favorites, trips: library.trips)
    }
}

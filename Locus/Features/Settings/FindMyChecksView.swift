import SwiftUI

struct FindMyChecksView: View {
    @ObservedObject private var remote = RemoteFindMyController.shared
    @ObservedObject private var computer = CompanionClient.shared
    var body: some View {
        List {
            Section {
                NavigationLink { RemoteFindMyView() } label: {
                    helper("Cloud helper", detail: "Works with your laptop off · Wi-Fi or cellular",
                           icon: "icloud", status: remote.enabled && remote.paired ? "In use" : remote.paired ? "Saved" : "Set up")
                }
                NavigationLink { ServiceChecksView() } label: {
                    helper("Windows helper", detail: "Laptop awake · Same Wi-Fi",
                           icon: "laptopcomputer", status: computer.enabled && computer.paired ? "In use" : computer.paired ? "Saved" : "Set up")
                }
            } header: { Text("Choose your helper") } footer: {
                Text("Use one helper at a time. You can keep both setups saved and switch here.")
            }.shiftSettingsRows()
            Section {
                Text("Find My reports appear in Shift and its Live Activity during a location session.")
                SettingsHelp(title: "What does a match mean?", lines: [
                    "A recent Apple location agreed with the point Shift sent at that time. This checks Devices, not People.",
                    "Helpers check about once a minute while iOS lets Shift run. Apple's location can be older than the helper's reply.",
                    "The 3–15 second setting checks Shift's own connection. It does not make Apple refresh faster."
                ])
            }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("Find My checks").navigationBarTitleDisplayMode(.inline)
    }
    private func helper(_ title: String, detail: String, icon: String, status: String) -> some View {
        HStack(spacing: 12) {
            ShiftSettingsIcon(symbol: icon, color: .purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                Text(status).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8).frame(minHeight: 44)
    }
}

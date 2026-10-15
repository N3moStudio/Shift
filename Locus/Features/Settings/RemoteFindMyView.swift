import SwiftUI
import UniformTypeIdentifiers

struct RemoteFindMyView: View {
    @EnvironmentObject private var session: SpoofSession
    @ObservedObject private var remote = RemoteFindMyController.shared
    @State private var confirmDisconnect = false
    var body: some View {
        List {
            if remote.paired {
                Section {
                    Toggle("Use cloud helper", isOn: $remote.enabled)
                    Button(remote.testingConnection ? "Connecting…" : "Test connection") { Task { await remote.testConnection() } }
                        .frame(minHeight: 44).disabled(remote.testingConnection)
                    if let message = remote.connectionMessage { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                    Toggle("Warn me if checks fail", isOn: $remote.alerts)
                        .onChange(of: remote.alerts) { _, value in
                            if value { Task { _ = await SessionNotifications.shared.requestPermission() } }
                        }
                    FindMyEvidenceSummary()
                    Button { remote.checkNow() } label: {
                        Label(remote.checking ? "Checking…" : "Check now", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.disabled(!remote.enabled || !session.isSpoofing || remote.checking)
                    if !remote.enabled {
                        Text("Turn on checks to request a report.").font(.subheadline).foregroundStyle(.secondary)
                    } else if !session.isSpoofing {
                        Text("Start a location session on the Map to compare Find My with the locations sent.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let website = remote.helperWebsite {
                        Link(destination: website) {
                            Label("Open helper / sign in", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }
                    }
                    Button("Disconnect helper", role: .destructive) { confirmDisconnect = true }.frame(minHeight: 44)
                }.shiftSettingsRows()
            } else {
                Section {
                    Text("Check Find My while your laptop is off.").font(.headline)
                    Text("Needs your own cloud server and Apple sign-in.").foregroundStyle(.secondary)
                }.shiftSettingsRows()
            }
            Section {
                NavigationLink(remote.paired ? "Reconnect or import setup" : "Connect your helper") { RemoteFindMySetupView() }
            } footer: { Text("Find My Devices only. This does not check the People tab.") }.shiftSettingsRows()
            Section {
                SettingsHelp(lines: [
                    "Your cloud helper compares Apple's location report with the locations Shift sent. Your iPhone can use cellular.",
                    "Checks run about once a minute while iOS lets Shift run. Repeated failures slow retries to up to two minutes; Check now retries immediately. Old reports stop showing as a match.",
                    "Check now asks your helper for its latest report. It cannot force Apple to supply a newer location. Apple location age and Helper replied measure different things.",
                    "If checks stop, a scheduled reminder may appear. Focus, notification permissions, and iOS can affect delivery. A failed check does not stop spoofing."
                ])
                SettingsHelp(title: "Apple signed me out", lines: [
                    "Render: tap Open helper / sign in. Unlock the page with your helper key, then sign into Apple again. You can do this from your phone.",
                    "Oracle: open your server's terminal, stop the helper with Ctrl+C, run its serve command again, and sign in to Apple.",
                    "Then tap Check now here. You only need a new setup file if the server or its access key changed."
                ])
                SettingsHelp(title: "What is shared?", lines: [
                    "Your server receives up to five minutes of spoofed points and their times during a session. It keeps them in memory, then clears them when stopped or after 150 seconds without an update.",
                    "Your helper access key is protected on this iPhone and excluded from backups. Keep the setup file private.",
                    "The helper uses an unofficial Apple sign-in. It only requests locations, but Apple's session can allow broader account access. Your password is not saved to disk; the running helper holds your signed-in session.",
                    "Free servers can become unavailable. Sign in again after Apple logs you out or the server restarts."
                ])
            }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("Cloud helper").navigationBarTitleDisplayMode(.inline)
        .loggedConfirmationDialog("Disconnect Find My checks?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect helper", role: .destructive) { remote.unpair() }
        } message: { Text("Location spoofing continues. To reconnect checks, import your helper’s setup file again.") }
    }
}

/// The Apple report and the helper response are separate pieces of evidence.
struct FindMyEvidenceSummary: View {
    var useWindows = false
    @ObservedObject private var remote = RemoteFindMyController.shared
    @ObservedObject private var computer = CompanionClient.shared
    private var state: RemoteFindMyState { useWindows ? computer.activityStatus?.state ?? .ready : remote.state }
    private var reportDate: Date? {
        useWindows ? computer.reports.first { $0.provider == "findmy-device" }?.locatedAt.map { Date(timeIntervalSince1970: $0) } : remote.reportDate
    }
    private var repliedAt: Date? { useWindows ? computer.connectedAt : remote.checkedAt }
    var body: some View {
        ForegroundTimeline { _ in
            VStack(alignment: .leading, spacing: 12) {
                Label(state.title, systemImage: state == .match ? "checkmark.circle.fill" : "clock")
                    .font(.headline).foregroundStyle(state == .match ? LocusTheme.statusGood : .primary)
                if let date = reportDate { evidenceDate("Apple’s location report", date: date) }
                if let date = repliedAt { evidenceDate("Helper response", date: date) }
                if let message = useWindows ? computer.message ?? state.warning : state.warning { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                Text("A new helper response can contain an older Apple location. Check now cannot force Apple to refresh it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        }
    }
    private func evidenceDate(_ title: String, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium))
            Text(date, style: .relative).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel(Text(title) + Text(": ") + Text(date, style: .relative))
        }
    }
}

private struct RemoteFindMySetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var remote = RemoteFindMyController.shared
    @State private var endpoint = ""
    @State private var helperKey = ""
    @State private var showImport = false
    @State private var pending: Data?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                TextField("https://your-helper.onrender.com", text: $endpoint)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Helper website URL")
                SecureField("Helper key", text: $helperKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect") {
                    do { pending = try RemoteFindMyController.renderPairing(endpoint: endpoint, helperKey: helperKey) }
                    catch { self.error = "Enter your HTTPS onrender.com address and the helper key from Render’s Environment settings." }
                }.frame(minHeight: 44).disabled(endpoint.isEmpty || helperKey.isEmpty)
            } header: { Text("Connect Render") } footer: {
                Text("Use SHIFT_ADMIN_KEY from your own Render service. Your Apple password belongs on your helper’s sign-in page.")
            }.shiftSettingsRows()
            Section {
                Button { showImport = true } label: {
                    Label("Import setup file instead", systemImage: "square.and.arrow.down").frame(minHeight: 44)
                }
            } footer: { Text("Existing ShiftFindMyPairing.json files still work, including setups on your own server.") }.shiftSettingsRows()
            Section("Need a helper?") {
                if let file = Bundle.main.url(forResource: "Shift-FindMy-Cloud", withExtension: "zip") {
                    ShareLink(item: file) { Label("Save helper & setup guide", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                }
                SettingsHelp(title: "Setup & sign-in help", lines: [
                    "Follow RENDER-SETUP.txt in the download to create your own service. Then enter its website and helper key above.",
                    "Open the helper website, sign in to Apple, and select your iPhone. Return to Cloud helper and tap Test connection.",
                    "Your saved connection keeps working after a server restart if the URL and helper key stay the same. Apple may need you to sign in again.",
                    "Free servers can sleep or restart. A connected helper does not guarantee a fresh Apple location."
                ])
            }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("Connect cloud helper").navigationBarTitleDisplayMode(.inline)
        .onDisappear { helperKey = "" }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 4096 else { throw RemoteFindMyController.RemoteError.invalid }
                let data = try Data(contentsOf: url)
                guard let link = try? JSONDecoder().decode(RemoteFindMyLink.self, from: data), link.valid else { throw RemoteFindMyController.RemoteError.invalid }
                pending = data
            } catch { if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription } }
        }
        .loggedAlert("Connect your private cloud helper?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Connect") {
                if let pending { do { try remote.pair(pending); helperKey = ""; dismiss() } catch { self.error = error.localizedDescription } }
                pending = nil
            }
        } message: {
            Text("Only connect your own helper. Turning on checks shares recent spoofed points and their times with that server during your session. It reads Find My Devices; it cannot control spoofing.")
        }
        .loggedAlert("Cloud helper", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

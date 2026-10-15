import SwiftUI
import UniformTypeIdentifiers

struct ConnectionDetailsView: View {
    @ObservedObject private var computer = CompanionClient.shared
    var body: some View {
        List {
            SessionSettingsSections(category: .connection)
            Section("Find My evidence") {
                FindMyEvidenceSummary(useWindows: computer.enabled)
                NavigationLink("Find My checks & helper") { FindMyChecksView() }
            }.shiftSettingsRows()
            Section { NavigationLink("Connection settings") { ConnectionSettingsView() } }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("Connection details").navigationBarTitleDisplayMode(.inline)
    }
}

struct ExperimentalFeaturesView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { RemoteFindMyView() } label: {
                    experiment("Remote Find My", detail: "Uses your own cloud server", icon: "icloud")
                }
                NavigationLink { ServiceChecksView() } label: {
                    experiment("Find My & Life360", detail: "Uses a Windows computer on the same Wi-Fi", icon: "laptopcomputer")
                }
            } header: { Text("Service checks") } footer: { Text("Optional tests. Reports can be delayed or unavailable.") }.shiftSettingsRows()
            Section("Testing tools") {
                NavigationLink { iPhoneLocationCheckView() } label: { Label("Check iPhone location", systemImage: "location.magnifyingglass") }
                NavigationLink { ReliabilityTestView() } label: { Label("Test a session", systemImage: "waveform.path.ecg") }
            }.shiftSettingsRows()
            Section {
                SettingsHelp(lines: [
                    "These tools double-check a session. You do not need them to spoof.",
                    "A match applies to the report's time. It is not proof of what someone sees right now.",
                    "Find My checks Devices only. They do not check the People tab."
                ])
            }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("Experimental Features").navigationBarTitleDisplayMode(.inline)
    }
    private func experiment(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 13) {
            ShiftSettingsIcon(symbol: icon, color: .purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
    }
}

private struct iPhoneLocationCheckView: View {
    @EnvironmentObject private var session: SpoofSession
    var body: some View { iPhoneLocationEvidenceView(check: session.verification, session: session) }
}

private struct iPhoneLocationEvidenceView: View {
    @ObservedObject var check: LocationVerificationController
    @ObservedObject var session: SpoofSession
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            Section {
                ForegroundTimeline { timeline in
                    CheckEvidenceRow(result: VerificationResult.evaluate(check.report, history: check.history, now: timeline,
                        active: session.effectivePhase == .active, requestedAfter: check.requestedAt))
                }
                if check.requestedAt != nil { Text(check.message).font(.footnote).foregroundStyle(.secondary) }
                Button("Check now") { check.check() }.frame(minHeight: 44)
                    .disabled(session.effectivePhase != .active || scenePhase != .active)
                if session.effectivePhase != .active { Text("Start a spoofing session first.").font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("Checks what this iPhone reports to Shift. It cannot check another app.") }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("iPhone location check").navigationBarTitleDisplayMode(.inline)
        .onDisappear { check.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { check.cancel() } }
    }
}

struct ServiceChecksView: View {
    @EnvironmentObject private var session: SpoofSession
    @ObservedObject private var companion = CompanionClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    private var canCheck: Bool { visible && scenePhase == .active }
    var body: some View {
        List {
            if companion.paired {
                Section("Connection") {
                    Toggle("Use Windows helper", isOn: $companion.enabled)
                    if let endpoint = companion.endpoint { Text(endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let date = companion.connectedAt {
                        Text("Helper replied ") + Text(date, style: .relative)
                    }
                    if let message = companion.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                    Button(companion.fetching ? "Connecting…" : "Test connection") { Task { await companion.refresh() } }
                        .frame(minHeight: 44).disabled(companion.fetching || !canCheck)
                }.shiftSettingsRows()
                Section("Latest reports") {
                    ForegroundTimeline { timeline in
                        ForEach(companion.reports.filter { $0.provider != "findmy-person" }) { report in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(report.providerName).font(.headline)
                                Text(report.target).font(.caption).foregroundStyle(.secondary)
                                CheckEvidenceRow(result: VerificationResult.evaluate(report, history: session.verification.history,
                                    now: timeline, active: session.effectivePhase == .active))
                                if let timestamp = report.locatedAt {
                                    HStack { Text("Location age:"); Text(Date(timeIntervalSince1970: timestamp), style: .relative) }.font(.caption)
                                }
                            }
                        }
                    }
                    Button(companion.fetching ? "Checking…" : "Refresh reports") { Task { await companion.refresh() } }
                        .frame(minHeight: 44).disabled(companion.fetching || !canCheck)
                    Button("Disconnect computer", role: .destructive) { companion.unpair() }
                }.shiftSettingsRows()
            }
            Section {
                Text("Laptop awake · Same Wi-Fi").font(.subheadline).foregroundStyle(.secondary)
                NavigationLink(companion.paired ? "Setup & help" : "Set up computer checks") { CompanionSetupView() }
            }.shiftSettingsRows()
            Section {
                SettingsHelp(lines: [
                    "When enabled, checks refresh about once a minute during a location session while iOS lets Shift run. Reports also appear in the Live Activity. Keep your laptop awake on the same Wi-Fi.",
                    "A match means the reported location agreed with what Shift sent at that time. An old report does not confirm your current location.",
                    "Find My checks Devices, not People. These service connections are unofficial and may stop working."
                ])
            }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("Windows helper").navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true }
        .onDisappear { visible = false; if !companion.enabled { companion.cancel() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active && !companion.enabled { companion.cancel() } }
        .task(id: "\(canCheck)-\(companion.paired)-\(companion.enabled)") {
            guard canCheck, !companion.enabled else { return }
            while !Task.isCancelled {
                if companion.paired { await companion.refresh() }
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            }
        }
    }
}

private struct CheckEvidenceRow: View {
    let result: VerificationResult
    var body: some View {
        Label(result.text, systemImage: result.kind == .match ? "checkmark.circle" : result.kind == .different ? "exclamationmark.circle" : "clock")
            .font(.subheadline).foregroundStyle(result.kind == .match ? Color.green : result.kind == .different ? Color.orange : Color.secondary)
    }
}

private struct CompanionSetupView: View {
    @ObservedObject private var companion = CompanionClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
    @State private var pendingLink: Data?
    @State private var importError: String?
    var body: some View {
        List {
            Section("On your laptop") {
                if let file = Bundle.main.url(forResource: "Shift-Windows-Helper", withExtension: "zip") {
                    ShareLink(item: file) { Label("Save Windows helper", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                }
                Text("Extract the ZIP, open Start Companion.cmd, then sign in and choose your iPhone.")
            }.shiftSettingsRows()
            Section("On this iPhone") {
                Button { showImport = true } label: {
                    Label("Import setup file", systemImage: "square.and.arrow.down").frame(minHeight: 44)
                }
                Text("Transfer ShiftCompanionPairing.json from your laptop. Keep it private.").font(.footnote).foregroundStyle(.secondary)
            }.shiftSettingsRows()
            Section {
                SettingsHelp(title: "Connection help", lines: [
                    "Leave the helper open and both devices on the same Wi-Fi. After importing, tap Test connection, then enable Use Windows helper.",
                    "The updated helper detects a local address and reuses its pairing after a restart on that address. If your laptop’s address changes, import the new file.",
                    "If Safari reaches the helper but shows 401 Unauthorized, the network works. Shift must send the key from the matching setup file.",
                    "Allow Local Network access for Shift or its host app (LiveContainer/SideStore). Allow the helper through Windows Firewall on your trusted network.",
                    "Older LocusCompanionPairing.json files can still be imported. This is separate from the device pairing used to spoof."
                ])
                SettingsHelp(title: "Install help & Life360", lines: [
                    "Install Python 3.12 or 3.13 on Windows with Add Python to PATH selected. The first helper launch installs dependencies.",
                    "Life360 is optional. Use a separate consenting viewer account that can already see you in your Circle; using this iPhone’s account may sign it out."
                ])
                Link("Get Python", destination: URL(string: "https://www.python.org/downloads/windows/")!)
            }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("Connect Windows helper").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 4096 else { throw CompanionClient.CompanionError.invalid }
                let data = try Data(contentsOf: url)
                guard let link = try? JSONDecoder().decode(CompanionLink.self, from: data), link.valid else { throw CompanionClient.CompanionError.invalid }
                pendingLink = data
            } catch {
                if (error as NSError).code != NSUserCancelledError { importError = error.localizedDescription }
            }
        }
        .loggedAlert("Pair this computer?", isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } })) {
            Button("Cancel", role: .cancel) { pendingLink = nil }
            Button("Pair") {
                if let pendingLink { do { try companion.pair(data: pendingLink); dismiss() } catch { importError = error.localizedDescription } }
                pendingLink = nil
            }
        } message: { Text("Only import a file from your own Shift helper. It lets this iPhone read that computer's selected location reports.") }
        .loggedAlert("Pairing file", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
    }
}

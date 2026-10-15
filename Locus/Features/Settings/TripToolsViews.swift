import SwiftUI
import MapKit

struct TripRecoveryView: View {
    @EnvironmentObject private var recovery: TripRecoveryStore
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = SetupConnectionModel()
    @State private var confirmDiscard = false

    var body: some View {
        List {
            Section {
                Toggle("Remember interrupted trips", isOn: $recovery.enabled)
                    .onChange(of: recovery.enabled) { _, enabled in if !enabled { session.discardRecovery() } }
            } footer: {
                Text("Resuming after Shift closes needs Wi-Fi and LocalDevVPN. Cellular alone cannot restart the connection.")
            }.shiftSettingsRows()
            Section {
                SettingsHelp(lines: [
                    "Keeps one recovery point on this phone, about every 10 seconds and when you leave the app.",
                    "A sudden close can leave the saved point slightly behind. Recovery only starts when you tap Resume; it can wait until Wi-Fi is available."
                ])
            }.shiftSettingsRows()
            if session.recoveryAvailable, let saved = recovery.checkpoint, let route = saved.trip.plannedRoute {
                Section("Interrupted trip") {
                    Text(saved.trip.name).font(.headline)
                    Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                        MapPolyline(coordinates: route.coordinates).stroke(LocusTheme.accent, lineWidth: 4)
                        Marker("Saved point", coordinate: route.track.point(at: saved.metres).coordinate)
                    }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 16))
                    LabeledContent("Saved progress", value: JourneyText.distance(saved.metres))
                    LabeledContent("Saved", value: saved.savedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("Resumes from the saved point, including any remaining stops.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Label(connection.wifiAvailable == true ? "Wi-Fi ready" : "Connect to Wi-Fi first", systemImage: "wifi")
                    Label("Keep LocalDevVPN turned on", systemImage: "lock.shield")
                    if !pairing.hasPairingFile { Text("Import your pairing file in Connection settings first.").foregroundStyle(LocusTheme.statusWarn) }
                    Button {
                        if session.resumeSavedTrip(pairing: pairing, wifiAvailable: connection.wifiAvailable == true) { dismiss() }
                    } label: {
                        Label("Resume trip", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.borderedProminent)
                        .disabled(connection.wifiAvailable != true || !pairing.hasPairingFile || session.isBusy || scenePhase != .active)
                    Button("Discard recovery point", role: .destructive) { confirmDiscard = true }
                }.shiftSettingsRows()
            } else {
                Section {
                    Text(session.journey == nil ? "No interrupted trip to resume." : "Your current trip is running in this app. Use the map to pause or continue it.")
                        .foregroundStyle(.secondary)
                }.shiftSettingsRows()
            }
            if let error = recovery.error {
                Section {
                    Text(error).foregroundStyle(LocusTheme.statusWarn)
                    Button("Clear recovery data", role: .destructive) { confirmDiscard = true }
                }.shiftSettingsRows()
            }
        }
        .shiftSettingsScreen().loggedNavigationTitle("Trip recovery").navigationBarTitleDisplayMode(.inline)
        .onAppear { connection.startMonitoring() }
        .onDisappear { connection.stopMonitoring() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connection.startMonitoring(); connection.refreshTunnel() }
            else { connection.stopMonitoring() }
        }
        .loggedConfirmationDialog("Discard the saved recovery point?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { session.discardRecovery() }
        } message: { Text("This removes the saved route progress. It does not stop or clear a location already set on your phone.") }
    }
}

struct ReliabilityTestView: View {
    @EnvironmentObject private var recorder: ReliabilityRecorder
    @EnvironmentObject private var session: SpoofSession
    @State private var baselineID: Date?
    private var olderResults: [ReliabilityRun] { recorder.history.runs.filter { $0.id != recorder.run?.id } }
    private var baseline: ReliabilityRun? { olderResults.first { $0.id == baselineID } ?? olderResults.first }

    var body: some View {
        List {
            Section {
                Text("Compare sessions of similar length and phone use. Battery readings cover your whole iPhone.")
                    .foregroundStyle(.secondary)
            }.shiftSettingsRows()
            if let run = recorder.run {
                Section(run.running ? "Test running" : "Last test") {
                    ReliabilityResultRows(run: run)
                    if run.running {
                        Button("End test") { recorder.finish() }.frame(minHeight: 44)
                    } else {
                        Button("Delete result", role: .destructive) { recorder.clear() }.frame(minHeight: 44)
                    }
                }.shiftSettingsRows()
            }
            if !recorder.running {
                Section {
                    Button {
                        guard session.isSpoofing else { return }
                        recorder.start(confirmedAt: session.lastConfirmedAt, configuration: session.reliabilityConfiguration)
                    } label: {
                        Label(recorder.run == nil ? "Start test" : "Start another test", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }.buttonStyle(.borderedProminent).disabled(!session.isSpoofing)
                    if !session.isSpoofing { Text("Start a location session first.").font(.caption).foregroundStyle(.secondary) }
                }.shiftSettingsRows()
            }
            if let run = recorder.run, let previous = baseline {
                Section("Compare with a previous test") {
                    Picker("Previous test", selection: Binding(get: { baseline?.id ?? previous.id }, set: { baselineID = $0 })) {
                        ForEach(olderResults) { result in
                            Text(result.startedAt.formatted(date: .abbreviated, time: .shortened)).tag(result.id)
                        }
                    }.pickerStyle(.menu)
                    ReliabilityComparisonRows(current: run, previous: previous)
                }.shiftSettingsRows()
            }
            if !olderResults.isEmpty {
                Section {
                    ForEach(olderResults) { result in
                        NavigationLink {
                            List { Section { ReliabilityResultRows(run: result) }.shiftSettingsRows() }
                                .shiftSettingsScreen().loggedNavigationTitle("Test result").navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.startedAt.formatted(date: .abbreviated, time: .shortened))
                                Text("\(JourneyText.duration(result.duration)) · \(ReliabilityResultText.battery(result))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.frame(minHeight: 44).fixedSize(horizontal: false, vertical: true)
                        }
                    }.onDelete { offsets in
                        let ids = olderResults.map(\.id)
                        for index in offsets { recorder.removeResult(id: ids[index]) }
                    }
                } header: { Text("Saved tests") } footer: { Text("The last eight completed tests stay on this iPhone.") }
                    .shiftSettingsRows()
            }
            Section {
                SettingsHelp(title: "Understanding the result", lines: [
                    "Unconfirmed means Shift had no fresh evidence. iOS may have paused the app; it does not prove the spoof disappeared.",
                    "This watches your current session without sending extra location updates. It cannot check Find My or another person's screen.",
                    "Away from Shift includes other apps, interruptions and a locked screen. It is not a measurement of screen-off time. Low Power Mode timing uses its last observed setting.",
                    "Compare tests lasting at least 20 minutes under similar conditions. Other apps, brightness and signal strength affect battery change; it cannot be attributed to Shift alone.",
                    "Results stay here and contain no locations. Charging makes battery drops unsuitable for comparison. Stop spoofing also ends the test."
                ])
            }.shiftSettingsRows()
        }
        .shiftSettingsScreen().loggedNavigationTitle("Battery & reliability").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !olderResults.isEmpty { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        }
    }
}

private enum ReliabilityResultText {
    static func battery(_ run: ReliabilityRun) -> String {
        if run.chargingObserved { return "Charging detected" }
        guard let drop = run.batteryDrop else { return "Unavailable" }
        if drop == 0 { return "No change recorded" }
        return drop > 0 ? "Down \(drop) percentage points" : "Up \(-drop) percentage points"
    }
    static func time(_ seconds: TimeInterval?) -> String { seconds.map { JourneyText.duration($0) } ?? "Not recorded" }
}

private struct ReliabilityResultRows: View {
    let run: ReliabilityRun
    var body: some View {
        LabeledContent("Started", value: run.startedAt.formatted(date: .abbreviated, time: .shortened))
        LabeledContent("Observed time", value: JourneyText.duration(run.duration))
        LabeledContent("Phone battery", value: ReliabilityResultText.battery(run))
        LabeledContent("In Shift", value: ReliabilityResultText.time(run.usage?.inAppSeconds))
        LabeledContent("Away from Shift", value: ReliabilityResultText.time(run.usage?.awaySeconds))
        LabeledContent("Unconfirmed periods", value: "\(run.gapCount)")
        LabeledContent("Time unconfirmed", value: JourneyText.duration(run.totalUnconfirmed(at: run.lastObservedAt)))
        LabeledContent("Failed updates", value: "\(run.failedCommands)")
        DisclosureGroup("Test conditions") {
            LabeledContent("Low Power Mode time", value: ReliabilityResultText.time(run.usage?.lowPowerSeconds))
            if let configuration = run.configuration {
                LabeledContent("App build", value: configuration.appVersion)
                LabeledContent("Starting session", value: configuration.activity.title)
                LabeledContent("Find My checks at start", value: configuration.findMyEnabled ? "On" : "Off")
                LabeledContent("Live Activities at start", value: configuration.liveActivityEnabled ? "On" : "Off")
                if run.usage?.configurationChanged == true {
                    Text("Session type or checking options changed during this test.").font(.footnote).foregroundStyle(.secondary)
                }
            } else { Text("Setup details were not saved by this older version.").foregroundStyle(.secondary) }
        }
        if run.interrupted {
            Text("Shift closed before the test ended. Results stop at its last saved observation.")
                .foregroundStyle(LocusTheme.statusWarn).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ReliabilityComparisonRows: View {
    let current: ReliabilityRun
    let previous: ReliabilityRun
    var body: some View {
        comparison("Observed time", JourneyText.duration(current.duration), JourneyText.duration(previous.duration))
        comparison("Phone battery", ReliabilityResultText.battery(current), ReliabilityResultText.battery(previous))
        comparison("In Shift", ReliabilityResultText.time(current.usage?.inAppSeconds), ReliabilityResultText.time(previous.usage?.inAppSeconds))
        comparison("Away from Shift", ReliabilityResultText.time(current.usage?.awaySeconds), ReliabilityResultText.time(previous.usage?.awaySeconds))
        comparison("Unconfirmed periods", String(current.gapCount), String(previous.gapCount))
        comparison("Time unconfirmed", JourneyText.duration(current.totalUnconfirmed(at: current.lastObservedAt)),
                   JourneyText.duration(previous.totalUnconfirmed(at: previous.lastObservedAt)))
        let notes = ReliabilityHistory.comparisonNotes(current, previous)
        if !notes.isEmpty {
            DisclosureGroup("Comparison notes (\(notes.count))") {
                ForEach(notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
    private func comparison(_ label: String, _ now: String, _ before: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text("Current: \(now)").fixedSize(horizontal: false, vertical: true)
            Text("Previous: \(before)").fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

struct PanelShortcutsView: View {
    @EnvironmentObject private var preferences: SessionPreferences
    var body: some View {
        List {
            Section {
                ForEach(preferences.panelShortcuts) { item in
                    Label(item.title, systemImage: item.icon).deleteDisabled(preferences.panelShortcuts.count == 1)
                }
                .onMove { indices, destination in preferences.panelShortcuts.move(fromOffsets: indices, toOffset: destination) }
                .onDelete { indices in
                    var items = preferences.panelShortcuts
                    items.remove(atOffsets: indices)
                    preferences.panelShortcuts = items
                }
            } header: { Text("On your panel") } footer: {
                Text("Choose up to 3. Drag to reorder. Other controls stay in More.")
            }.shiftSettingsRows()
            Section("Add a shortcut") {
                ForEach(PanelShortcut.allCases.filter { !preferences.panelShortcuts.contains($0) }) { item in
                    Button { preferences.panelShortcuts.append(item) } label: {
                        Label(item.title, systemImage: item.icon).frame(minHeight: 44)
                    }.disabled(preferences.panelShortcuts.count >= 3)
                }
            }.shiftSettingsRows()
            Button("Reset shortcuts") { preferences.panelShortcuts = PanelShortcut.defaults }
        }
        .environment(\.editMode, .constant(.active))
        .shiftSettingsScreen().loggedNavigationTitle("Panel shortcuts").navigationBarTitleDisplayMode(.inline)
    }
}

struct LibraryFolderSheet: View {
    var current: String?
    let folders: [String]
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("New folder name", text: $name).onChange(of: name) { _, value in name = String(value.prefix(60)) }
                    Button("Save to this folder") { choose(name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Existing folders") {
                    Button("No folder") { choose("") }
                    ForEach(folders, id: \.self) { folder in
                        Button { choose(folder) } label: {
                            HStack { Text(folder); Spacer(); if folder == current { Image(systemName: "checkmark") } }
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                    }
                }
            }.shiftScreen().loggedNavigationTitle("Choose folder").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private func choose(_ value: String) { onChoose(value); dismiss() }
}

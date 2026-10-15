import SwiftUI
import UniformTypeIdentifiers

struct DeveloperLogExportSection: View {
    @State private var recording = DeveloperLogStore.shared.enabled
    @State private var summary: DeveloperLogStore.Summary?
    @State private var document = DeveloperLogDocument()
    @State private var exporting = false
    @State private var preparing = false
    @State private var confirmClear = false
    @State private var confirmExport = false
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Record developer log", isOn: $recording)
                .onChange(of: recording) { _, value in DeveloperLogStore.shared.setEnabled(value) }
            Button { confirmExport = true
            } label: {
                Label(preparing ? "Preparing log…" : "Export data log for developer", systemImage: "doc.text.magnifyingglass")
                    .frame(minHeight: 44)
            }.disabled(preparing)
            DisclosureGroup("Log tools") {
                NavigationLink { SessionTimelineView() } label: { Label("Session timeline", systemImage: "clock") }
                ProblemMomentButton()
                Menu("Mark a test event") {
                    ForEach(["About to turn Airplane Mode on", "Airplane Mode is off again", "About to force-close Shift", "Other app shows the new location", "Other app still shows the old location"], id: \.self) { event in
                        Button(event) {
                            DeveloperLogStore.shared.record("user_reported_test_event", ["description": event])
                            DeveloperLogStore.shared.maintenance(flush: true)
                            message = recording ? "Test marker added. Give Shift a moment to save it before closing." : "Turn on recording before adding a test marker."
                        }
                    }
                }
            }
            if let summary {
                Text("This batch: \(summary.start.formatted(date: .abbreviated, time: .shortened)) → \(summary.end.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                if summary.omitted > 0 { Text("The storage limit was reached. Some events were not recorded.").font(.caption).foregroundStyle(LocusTheme.statusWarn) }
                if summary.storageError { Text("Some events could not be saved. Check free storage.").font(.caption).foregroundStyle(LocusTheme.statusWarn) }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Button("Clear developer log", role: .destructive) { confirmClear = true }
            SettingsHelp(title: "What gets recorded?", lines: [
                "Actions, taps, exact coordinates, warnings, notification requests, and app/network changes. Passwords, pairing files, and keyboard text are excluded.",
                "The log resets every 48 hours when Shift can run. Files you exported are yours to delete. Storage is capped at 256 MB.",
                "iOS does not report every force-close or Airplane Mode change. Use Log tools → Mark a test event for those."
            ])
        } header: { Text("Developer log · 48 hours") } footer: {
            Text("Includes exact locations. Stored on this phone; shared only when you export it.")
        }.shiftSettingsRows()
        .task { summary = await DeveloperLogStore.shared.summary() }
        .loggedConfirmationDialog("Export a developer log?", isPresented: $confirmExport, titleVisibility: .visible) {
            Button("Prepare log") {
                preparing = true
                Task {
                    do {
                        document = DeveloperLogDocument(data: try await DeveloperLogStore.shared.export())
                        exporting = true
                    } catch { message = "The log couldn’t be exported. Check available storage and try again." }
                    preparing = false
                    summary = await DeveloperLogStore.shared.summary()
                }

            }
        } message: { Text("Includes exact locations and a history of your actions. This is a diagnostic file, not a backup. Review it before sharing.") }
        .fileExporter(isPresented: $exporting, document: document, contentType: .plainText,
                      defaultFilename: "Shift-developer-log.jsonl") { result in
            switch result {
            case .success: message = "Log exported. It includes exact locations; share it only with someone you choose."
            case .failure: message = "Export was cancelled or couldn’t finish. The current log is still on this phone."
            }
            document = DeveloperLogDocument()
        }
        .loggedConfirmationDialog("Clear this developer log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear log", role: .destructive) {
                Task { await DeveloperLogStore.shared.clear(); summary = await DeveloperLogStore.shared.summary() }
            }
        } message: { Text("Deletes the current batch and starts a new 48-hour window. Files you already exported stay where you saved them.") }
    }
}

private struct DeveloperLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SessionRetryButton: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @State private var showHelp = false
    var body: some View {
        Button {
            if session.reopenedWithoutConnection { showHelp = true }
            else { session.retry(pairing: pairing) }
        } label: {
            Text(session.reopenedWithoutConnection ? "Connection help" : "Retry connection")
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(session.isBusy)
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                List {
                    Section { Text(session.recoveryExplanation) }.shiftSettingsRows()
                    Section {
                        Button("Try clearing previous location") { showHelp = false; session.stop(pairing: pairing) }
                            .disabled(session.isBusy)
                    } footer: { Text("Use this when Wi-Fi and LocalDevVPN are available. This requests a clear; it doesn’t send a new fake location.") }.shiftSettingsRows()
                }
                .shiftSettingsScreen().loggedNavigationTitle("Connection after reopening")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
            }.presentationDetents([.medium, .large])
        }
    }
}

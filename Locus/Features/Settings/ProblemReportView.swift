import SwiftUI

struct ProblemReportView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @ObservedObject private var diagnostics = SessionDiagnostics.shared
    @State private var category: ProblemCategory = .other
    @State private var includeNotes = false
    @State private var notes = ""
    @State private var preview: ReportPreview?
    @State private var confirmClear = false

    private struct ReportPreview: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Form {
            Section {
                Text("Review your report before sharing. Nothing is sent automatically.")
                Picker("What went wrong?", selection: $category) {
                    ForEach(ProblemCategory.allCases) { Text($0.rawValue).tag($0) }
                }
            }.shiftSettingsRows()
            Section {
                Toggle("Add my own notes", isOn: $includeNotes)
                if includeNotes {
                    TextEditor(text: $notes)
                        .frame(minHeight: 110)
                        .accessibilityLabel("Describe what you did and what happened")
                        .onChange(of: notes) { _, value in
                            if value.count > 2_000 { notes = String(value.prefix(2_000)) }
                        }
                    Text("\(notes.count)/2,000 characters").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Describe what happened. Only include details you want to share.")
            }.shiftSettingsRows()
            Section {
                Button {
                    preview = ReportPreview(text: diagnostics.report(session: session, pairing: pairing,
                        category: category, includeNotes: includeNotes, notes: notes))
                } label: {
                    Label("Preview report", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
            } footer: {
                Text("Automatic details exclude locations and account information. Your notes are included if enabled.")
            }.shiftSettingsRows()
            Section {
                DisclosureGroup("Report options") {
                    Toggle("Keep short report events", isOn: $diagnostics.recordingEnabled)
                    Button("Clear troubleshooting events", role: .destructive) { confirmClear = true }
                    Text("Keeps up to 100 events for this app run. Turning it off clears them.").font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Need the full 48-hour log? Open Export or import at the bottom of Settings.")
            }.shiftSettingsRows()
        }
        .shiftSettingsScreen().loggedNavigationTitle("Report a problem")
        .navigationBarTitleDisplayMode(.inline)
        .loggedConfirmationDialog("Clear recent troubleshooting events?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear events", role: .destructive) { diagnostics.clear() }
        }
        .sheet(item: $preview) { report in
            ProblemReportPreview(text: report.text)
        }
    }
}

private struct ProblemReportPreview: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .shiftSettingsScreen().loggedNavigationTitle("Review your report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    ShareLink(item: text) {
                        Label("Share this report", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Choose where to send it in the next screen.").font(.caption).foregroundStyle(.secondary)
                }
                .padding().background(.regularMaterial)
            }
        }
    }
}

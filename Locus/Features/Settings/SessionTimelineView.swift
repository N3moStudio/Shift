import SwiftUI

struct ProblemMoment: Identifiable {
    let id = UUID()
    let time = Date()
}

struct ProblemMomentButton: View {
    @State private var moment: ProblemMoment?
    var body: some View {
        Button { moment = ProblemMoment() } label: {
            Label("Something went wrong", systemImage: "flag")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .sheet(item: $moment) { ProblemMomentSheet(moment: $0) }
    }
}

struct ProblemMomentSheet: View {
    let moment: ProblemMoment
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var marked = false
    @State private var started = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if marked {
                        Label("Moment saved", systemImage: "checkmark.circle").foregroundStyle(LocusTheme.statusGood)
                        Text(moment.time, format: .dateTime.hour().minute().second())
                    } else if error == nil { ProgressView("Saving this moment…") }
                    if let error { Text(error).foregroundStyle(LocusTheme.statusWarn) }
                } footer: {
                    Text("This marks the time in your local developer log. Nothing is sent automatically. Export the log from Settings → Export or import when you're ready to share it.")
                }.shiftSettingsRows()
                if marked {
                    Section {
                        TextField("What happened? (optional)", text: $note, axis: .vertical)
                            .lineLimit(3...5)
                            .onChange(of: note) { _, value in if value.count > 300 { note = String(value.prefix(300)) } }
                        Button {
                            saving = true
                            Task {
                                do {
                                    try await DeveloperLogStore.shared.addProblemNote(note, marker: moment.id)
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                                saving = false
                            }
                        } label: {
                            Text(saving ? "Saving…" : "Save note")
                                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.disabled(saving || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: { Text("You can leave without a note; the marked time stays saved. Notes are included in the developer export.") }.shiftSettingsRows()
                }
            }
            .shiftSettingsScreen().loggedNavigationTitle("Something went wrong").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
            .task {
                guard !started else { return }; started = true
                do { try await DeveloperLogStore.shared.markProblem(id: moment.id, at: moment.time); marked = true }
                catch { self.error = error.localizedDescription }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SessionTimelineView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: DeveloperLogStore.TimelineSnapshot?
    var body: some View {
        List {
            Section {
                ProblemMomentButton()
                if let snapshot {
                    if !snapshot.recording { Text("Recording is off. Existing moments stay until this batch resets.").foregroundStyle(LocusTheme.statusWarn) }
                    if snapshot.incomplete { Text("Some events may be missing because the log is full or storage was unavailable.").foregroundStyle(LocusTheme.statusWarn) }
                    Text("This batch ends \(snapshot.end.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Highlights from this 48-hour log batch, starting with this update. Successful location updates are grouped. The full developer export has more detail. Time when Shift couldn't run may be missing; we can't reliably detect force-closing or Airplane Mode.")
            }.shiftSettingsRows()
            if let snapshot {
                Section("Latest first") {
                    if snapshot.entries.isEmpty { Text("No recorded highlights yet.").foregroundStyle(.secondary) }
                    ForEach(snapshot.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.subheadline.weight(.semibold))
                            Text(entry.firstAt, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                            if entry.count > 1 {
                                Text("\(entry.count) updates · last at \(entry.lastAt.formatted(date: .omitted, time: .standard))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !entry.detail.isEmpty { Text(entry.detail).font(.footnote).foregroundStyle(.secondary) }
                        }.padding(.vertical, 3)
                    }
                    if snapshot.trimmed { Text("Showing the latest 1,000 highlights. Earlier detail may still be in this batch’s developer export.").font(.footnote).foregroundStyle(.secondary) }
                }.shiftSettingsRows()
            } else { ProgressView("Loading timeline…") }
        }
        .shiftSettingsScreen().loggedNavigationTitle("Session timeline").navigationBarTitleDisplayMode(.inline)
        .refreshable { snapshot = await DeveloperLogStore.shared.timeline() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                snapshot = await DeveloperLogStore.shared.timeline()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
}

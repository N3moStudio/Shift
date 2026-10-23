import MapKit
import SwiftUI

struct TripEditHistoryView: View {
    let tripID: UUID
    @EnvironmentObject private var library: TripLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    var body: some View {
        NavigationStack {
            List {
                if let current = library.trips.first(where: { $0.id == tripID }) {
                    Section("Saved now") {
                        Text(current.name).font(.headline)
                        Text("\(current.originName) → \(current.destinationName)").font(.subheadline)
                    }
                    Section {
                        let history = library.history(for: tripID)
                        if history.isEmpty { Text("Earlier versions appear here after you edit and save this trip.").foregroundStyle(.secondary) }
                        ForEach(history) { revision in
                            NavigationLink {
                                TripRevisionPreview(revision: revision)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(revision.trip.name)
                                    Text(revision.reason.title).font(.caption).foregroundStyle(.secondary)
                                    Text(revision.replacedAt, format: .dateTime.month().day().hour().minute().second())
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44)
                            }
                        }
                        if !history.isEmpty { Button("Delete earlier versions", role: .destructive) { confirmClear = true } }
                    } header: { Text("Earlier versions") } footer: {
                        Text("Keeps the last three versions on this iPhone. Restoring changes the saved trip only and keeps the version you replace. Backups export the current trip. Deleting a trip removes its edit history; Recently Deleted keeps its latest saved version.")
                    }
                } else { Text("This trip is no longer in Saved.") }
                if let error = library.error { Text(error).font(.footnote).foregroundStyle(LocusTheme.statusWarn) }
            }
            .shiftScreen().loggedNavigationTitle("Edit history").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .loggedConfirmationDialog("Delete this trip’s earlier versions?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete earlier versions", role: .destructive) { _ = library.clearHistory(for: tripID) }
            } message: { Text("The currently saved trip stays. Deleted earlier versions cannot be restored.") }
        }
    }
}

private struct TripRevisionPreview: View {
    @EnvironmentObject private var preferences: SessionPreferences
    let revision: TripRevision
    @EnvironmentObject private var library: TripLibrary
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @State private var expected: SavedTrip?
    @State private var confirmRestore = false
    @State private var message: String?
    private var unavailable: Bool { session.journey != nil || session.isBusy || expected == nil }

    var body: some View {
        List {
            Section {
                Map(interactionModes: []) {
                    MapPolyline(coordinates: revision.trip.points.map(\.coordinate)).stroke(LocusTheme.accent, lineWidth: 4)
                }
                .mapControlVisibility(.hidden).frame(height: 180).allowsHitTesting(false)
                Text(revision.trip.name).font(.headline)
                LabeledContent("Start", value: revision.trip.originName)
                LabeledContent("End", value: revision.trip.destinationName)
                LabeledContent("Mode", value: revision.trip.mode.title)
                LabeledContent("Speed", value: preferences.speedUnit.formatted(mph: revision.trip.speedMPH))
                LabeledContent("Folder", value: revision.trip.folder ?? "None")
                LabeledContent("Smooth movement", value: revision.trip.smoothMovement ? "On" : "Off")
                Text(revision.reason.title).font(.footnote).foregroundStyle(.secondary)
            }
            if !revision.trip.stops.isEmpty {
                Section("Stops in this version") {
                    ForEach(revision.trip.stops) { stop in
                        LabeledContent(stop.name, value: StopDuration.label(stop.waitSeconds))
                    }
                }
            }
            Section {
                Button { confirmRestore = true } label: {
                    Label("Restore this version", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.disabled(unavailable)
            } footer: {
                Text(session.journey != nil ? "Stop the current route before restoring a saved version."
                     : "Replaces this saved trip’s path, stops, names and travel settings. It won’t teleport or start moving. You can restore the version you replace from Edit history.")
            }
        }
        .shiftScreen().loggedNavigationTitle("Earlier version").navigationBarTitleDisplayMode(.inline)
        .onAppear { if expected == nil { expected = library.trips.first { $0.id == revision.trip.id } } }
        .loggedConfirmationDialog("Restore this saved version?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore version") {
                guard !unavailable, let expected else { message = "Stop the route and try again."; return }
                if library.restoreRevision(revision.id, for: revision.trip.id, expected: expected) { dismiss() }
                else { message = library.error }
            }
        } message: { Text("Your current saved version will move into Edit history. Your simulated location stays as it is.") }
        .loggedAlert("Couldn’t restore", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
}

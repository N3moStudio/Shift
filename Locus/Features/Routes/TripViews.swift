import SwiftUI
import MapKit

struct ArrivalControls: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var planner: RoutePlanner
    var body: some View {
        if session.journey?.state == .arrived {
            VStack(spacing: 8) {
                Picker("Next", selection: $session.arrivalChoice) {
                    ForEach(ArrivalChoice.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                if planner.continuationLoading {
                    HStack {
                        ProgressView("Finding connecting path…")
                        Spacer()
                        Button("Cancel") { planner.cancel() }.frame(minHeight: 44)
                    }.font(.caption)
                } else if session.arrivalChoice != .stay {
                    Button { planner.previewContinuation(choice: session.arrivalChoice, session: session) } label: {
                        Label(session.arrivalChoice.actionTitle, systemImage: "map")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.bordered).disabled(session.isBusy)
                }
                if let error = planner.error { Text(error).font(.caption).foregroundStyle(LocusTheme.statusWarn) }
            }
        }
    }
}

struct SavedTripsSection: View {
    @EnvironmentObject private var preferences: SessionPreferences
    @EnvironmentObject private var library: TripLibrary
    @EnvironmentObject private var session: SpoofSession
    let onChoose: (SavedTrip) -> Void
    var search = ""
    var folder: String?
    var folders: [String] = []
    var onCreate: (() -> Void)? = nil
    @State private var editingPath: SavedTrip?
    @State private var folderTrip: SavedTrip?
    @State private var historyTrip: SavedTrip?
    @State private var renaming: SavedTrip?
    @State private var name = ""
    @State private var copyNotice: String?

    var body: some View {
        Section {
            if library.trips.isEmpty {
                Text("Save a trip from the route planner to reuse its path, speed, and stops.").foregroundStyle(.secondary)
                if let onCreate {
                    Button("Create a route", systemImage: "point.topleft.down.to.point.bottomright.curvepath", action: onCreate)
                        .frame(minHeight: 44)
                }
            }
            ForEach(library.trips.filter {
                (folder == nil || $0.folder == folder) && SavedNameSearch.matches(search, trip: $0)
            }) { trip in
                HStack(spacing: 4) {
                Button { onChoose(trip) } label: {
                    HStack {
                        ShiftRowIcon(symbol: trip.mode.icon)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trip.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(trip.originName) → \(trip.destinationName)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(trip.mode.title) · \(preferences.speedUnit.formatted(mph: trip.speedMPH)) · \(trip.stops.count) stops")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).disabled(session.journey != nil || session.isBusy)
                Menu { tripActions(trip) } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.borderless).accessibilityLabel("Options for \(trip.name)")
                }
                .contextMenu { tripActions(trip) }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { duplicate(trip, edit: false) } label: { Label("Duplicate", systemImage: "doc.on.doc") }.tint(LocusTheme.accent)
                    Button("History") { historyTrip = trip }.tint(.indigo)
                }
                .swipeActions {
                    Button(role: .destructive) { library.remove(trip) } label: { Label("Delete", systemImage: "trash") }
                    Button { renaming = trip; name = trip.name } label: { Label("Rename", systemImage: "pencil") }.tint(.gray)
                }
            }
            if let copyNotice { Label(copyNotice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(LocusTheme.statusWarn) }
        } header: { Text("Saved trips") } footer: {
            Text(session.journey == nil ? "Tap a trip to plan it. Use ••• to copy, edit, or view its history." : "Stop your current route before opening another trip.")
        }
        .sheet(item: $historyTrip) { trip in TripEditHistoryView(tripID: trip.id) }
        .sheet(item: $editingPath) { trip in
            PathEditorSheet(title: "Edit path", points: trip.points, hasStops: !trip.stops.isEmpty || !(trip.travelSections ?? []).isEmpty) { points in
                library.replaceDrawnPath(trip, points: points) ? nil : library.error ?? "Couldn't save this path."
            }
        }
        .sheet(item: $folderTrip) { trip in
            LibraryFolderSheet(current: trip.folder, folders: folders) { library.move(trip, folder: $0) }
        }
        .loggedAlert("Rename trip", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Trip name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { if let renaming { library.rename(renaming, to: name) }; renaming = nil }
        }
        .task(id: copyNotice) {
            guard copyNotice != nil else { return }
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            copyNotice = nil
        }
    }

    @ViewBuilder private func tripActions(_ trip: SavedTrip) -> some View {
        Button("Duplicate", systemImage: "doc.on.doc") { duplicate(trip, edit: false) }
        Button("Duplicate and edit", systemImage: "square.and.pencil") { duplicate(trip, edit: true) }
            .disabled(session.journey != nil || session.isBusy)
        Divider()
        if trip.source == .drawn {
            Button("Edit path", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { editingPath = trip }
                .disabled(session.journey != nil || session.isBusy)
        }
        Button("Rename", systemImage: "pencil") { renaming = trip; name = trip.name }
        Button("Edit history", systemImage: "clock.arrow.circlepath") { historyTrip = trip }
        Button("Move to folder…", systemImage: "folder") { folderTrip = trip }
    }
    private func duplicate(_ trip: SavedTrip, edit: Bool) {
        guard !edit || (session.journey == nil && !session.isBusy) else { return }
        copyNotice = nil
        guard let copy = library.duplicate(trip) else { return }
        copyNotice = "Saved \(copy.name)"
        if edit { onChoose(copy) }
    }
}

struct AddPathStopSheet: View {
    let route: PlannedRoute
    var liveRoute = false
    let onAdd: (String, Double, Double) -> String?
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @State private var fraction = 0.5
    @State private var name = ""
    @State private var waitSeconds = 60.0
    @State private var error: String?
    var body: some View {
        ShiftEditorContainer {
            Form {
                Section {
                    Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                        MapPolyline(coordinates: route.coordinates).stroke(LocusTheme.accent, lineWidth: 4)
                        Marker("Stop", coordinate: route.track.point(at: fraction * route.track.length).coordinate).tint(.orange)
                        if liveRoute, session.activeRoute?.id == route.id, let progress = session.journey {
                            Marker("Current route position", systemImage: "location.fill", coordinate: route.track.point(at: progress.travelledMetres).coordinate).tint(LocusTheme.accentSecondary)
                        }
                    }.frame(height: 190)
                    Text("\(JourneyText.distance(fraction * route.track.length)) from start")
                    Slider(value: $fraction, in: 0...1).accessibilityLabel("Stop position along route")
                        .onChange(of: fraction) { _, _ in error = nil }
                    if liveRoute, let progress = session.journey {
                        Text("Current progress: \(JourneyText.distance(progress.travelledMetres)) from start")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Stop name", text: $name)
                    StopDurationControl(seconds: $waitSeconds)
                    if let error { Text(error).font(.caption).foregroundStyle(LocusTheme.statusWarn) }
                } footer: { Text(liveRoute
                    ? "The route keeps moving. Choose a point ahead; if you pass it before tapping Add, choose a later point. Your current pause and progress stay intact."
                    : "Adds a pause on this exact path. Use the slider to choose its position.") }
            }
            .shiftScreen().loggedNavigationTitle("Pause along path").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if liveRoute, let progress = session.journey {
                    fraction = min(1, progress.fraction + (1 - progress.fraction) / 2)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        error = onAdd(name, fraction, waitSeconds)
                        if error == nil { dismiss() }
                    }
                }
            }
        }
    }
}

struct RouteExtrasControls: View {
    @EnvironmentObject private var session: SpoofSession
    var body: some View {
        if let stop = session.currentStop {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.name).lineLimit(1)
                    Text("\(session.routePaused ? "Paused · " : "")\(Int(ceil(session.stopProgress.remainingSeconds))) sec left")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button { session.continueFromStop() } label: {
                    Text("Continue now").padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!session.canEditRouteMovement || !session.isSpoofing)
            }.font(.caption.weight(.semibold))
        }
    }
}

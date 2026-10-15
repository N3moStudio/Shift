import MapKit
import SwiftUI

struct RoutePlaceSearchSheet: View {
    let title: String
    let onChoose: (RoutePlace) -> Void
    let onPreviewTeleport: ((RoutePlace) -> Void)?
    let allowsDeviceOrigin: Bool
    let onChooseTrip: ((SavedTrip) -> Void)?
    @EnvironmentObject private var library: TripLibrary
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = PlaceSearchCompleter()
    @State private var query = ""
    @State private var isResolving = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var activeSearch: MKLocalSearch?
    @State private var searchGeneration = UUID()
    @State private var selectedPlace: RoutePlace?
    @State private var showPlaceActions = false
    @State private var showDeviceLocation = false
    @State private var pendingDeviceOrigin: RoutePlace?

    init(title: String, onPreviewTeleport: ((RoutePlace) -> Void)? = nil, allowsDeviceOrigin: Bool = false,
         onChooseTrip: ((SavedTrip) -> Void)? = nil, onChoose: @escaping (RoutePlace) -> Void) {
        self.title = title
        self.onChooseTrip = onChooseTrip
        self.onPreviewTeleport = onPreviewTeleport
        self.allowsDeviceOrigin = allowsDeviceOrigin
        self.onChoose = onChoose
    }

    var body: some View {
        ShiftEditorContainer {
            List {
                if isResolving {
                    HStack {
                        ProgressView("Finding place…")
                        Spacer()
                        Button("Cancel search") { cancelSearch() }.buttonStyle(.borderless)
                    }
                }
                if let error { Text(error).foregroundStyle(LocusTheme.statusWarn) }
                if query.isEmpty {
                    ShiftScreenHeading(eyebrow: "Places", title: "Where to?", detail: "Find a place or return to a favorite.")
                    Section("Use a location") {
                        if allowsDeviceOrigin {
                            Button {
                                showDeviceLocation = true
                            } label: { Label("Use device location", systemImage: "location.fill") }
                        }
                        if let current = session.defaultRouteOrigin, !allowsDeviceOrigin || session.hasSession {
                            Button { choose(current) } label: { Label(current.name, systemImage: "location") }
                        }
                        if let pin = session.pin {
                            Button { choose(RoutePlace(name: session.suggestedFavoriteName(for: pin), coordinate: pin)) } label: {
                                Label("Selected map pin · \(session.suggestedFavoriteName(for: pin))", systemImage: "mappin")
                            }
                        }
                    }
                    Section("Saved places") {
                        ForEach(session.favorites) { place in
                            Button(place.displayName) { choose(RoutePlace(name: place.displayName, coordinate: place.coordinate)) }
                        }
                    }
                    Section("Recent places") {
                        ForEach(session.recents.prefix(8)) { place in
                            Button(place.displayName) { choose(RoutePlace(name: place.displayName, coordinate: place.coordinate)) }
                        }
                    }
                } else {
                    savedMatches
                    ForEach(completer.results, id: \.self) { completion in
                        Button {
                            resolve(MKLocalSearch.Request(completion: completion))
                        } label: {
                            HStack(spacing: 14) {
                                ShiftRowIcon(symbol: "mappin.and.ellipse")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(completion.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                        }
                    }
                    Button("Search for “\(query)”") {
                        let request = MKLocalSearch.Request()
                        request.naturalLanguageQuery = query
                        resolve(request)
                    }
                }
            }
            .searchable(text: $query, prompt: "Saved name, address, or place")
            .onChange(of: query) { _, value in
                cancelSearch()
                selectedPlace = nil
                showPlaceActions = false
                completer.query = value
                error = nil
            }
            .onSubmit(of: .search) {
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                resolve(request)
            }
            .shiftScreen().loggedNavigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancelSearch(); dismiss() } } }
            .loggedConfirmationDialog(selectedPlace?.name ?? "Selected place", isPresented: $showPlaceActions, titleVisibility: .visible) {
                if let place = selectedPlace, let onPreviewTeleport {
                    Button("Teleport") {
                        session.pushNamedRecent(name: place.name, coordinate: place.coordinate)
                        onPreviewTeleport(place)
                        selectedPlace = nil
                        dismiss()
                    }
                    Button("Plan a route") { openPlanner(place) }
                }
                Button("Cancel", role: .cancel) { selectedPlace = nil }
            } message: { Text("Teleport shows a pin first. Confirm on the map when you're ready.") }
            .sheet(isPresented: $showDeviceLocation, onDismiss: {
                if let place = pendingDeviceOrigin { pendingDeviceOrigin = nil; choose(place) }
            }) {
                DeviceOriginSheet { place in pendingDeviceOrigin = place; showDeviceLocation = false }
                    .presentationDetents([.medium])
            }
            .onDisappear { cancelSearch() }
        }
    }

    @ViewBuilder private var savedMatches: some View {
        let places = session.favorites.filter { SavedNameSearch.matches(query, fields: [$0.displayName, $0.folder ?? ""]) }
        if !places.isEmpty {
            Section("Your saved places") {
                ForEach(places.prefix(20)) { place in
                    Button { choose(RoutePlace(name: place.displayName, coordinate: place.coordinate)) } label: {
                        Label(place.displayName, systemImage: "star")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                }
                if places.count > 20 { Text("More matches are available in Saved.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        if let onChooseTrip {
            let trips = library.trips.filter { SavedNameSearch.matches(query, trip: $0) }
            if !trips.isEmpty {
                Section {
                    ForEach(trips) { trip in
                        Button { cancelSearch(); onChooseTrip(trip); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(trip.name, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                                Text("\(trip.originName) → \(trip.destinationName)").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.disabled(session.journey != nil || session.isBusy)
                    }
                } header: { Text("Your saved trips") } footer: {
                    Text(session.journey != nil ? "Stop your current route before opening a saved trip."
                         : "Opens the saved trip in the planner. Tap Show Route, then Start Route on the map when you're ready.")
                }
            }
        }
    }

    private func choose(_ place: RoutePlace) {
        cancelSearch()
        if onPreviewTeleport != nil {
            selectedPlace = place
            showPlaceActions = true
        } else { openPlanner(place) }
    }

    private func openPlanner(_ place: RoutePlace) {
        session.pushNamedRecent(name: place.name, coordinate: place.coordinate)
        onChoose(place)
        selectedPlace = nil
        dismiss()
    }

    private func cancelSearch() {
        searchGeneration = UUID()
        activeSearch?.cancel()
        activeSearch = nil
        searchTask?.cancel()
        searchTask = nil
        isResolving = false
    }

    private func resolve(_ request: MKLocalSearch.Request) {
        cancelSearch()
        let generation = searchGeneration
        let fallbackName = query
        let search = MKLocalSearch(request: request)
        activeSearch = search
        isResolving = true
        error = nil
        searchTask = Task { @MainActor in
            do {
                let response = try await search.start()
                guard !Task.isCancelled, generation == searchGeneration else { return }
                isResolving = false
                activeSearch = nil
                guard let item = response.mapItems.first else { error = "No matching place found. Try a more specific address."; searchTask = nil; return }
                let coordinate = item.placemark.coordinate
                let saved = session.favorites.first { RoutePoint($0.coordinate).distance(to: RoutePoint(coordinate)) <= 5 && !PlaceLabel.isCoordinate($0.name) }
                choose(RoutePlace(name: saved?.name ?? item.name ?? fallbackName, coordinate: coordinate))
            } catch {
                guard !Task.isCancelled, generation == searchGeneration else { return }
                isResolving = false
                activeSearch = nil
                searchTask = nil
                self.error = error.localizedDescription
            }
        }
    }
}

private struct DeviceOriginSheet: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var waitedForFix = false
    let onChoose: (RoutePlace) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(session.hasSession
                         ? "Your phone may report the fake location while spoofing. This option uses the device location saved before you started. It might be old—check the time below."
                         : "Uses the latest location your phone reports.")
                    if session.hasSession {
                        Text("This only chooses where the route starts. It doesn't stop or move your current spoof. You can also search for your real starting address.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForegroundTimeline { context in
                        if let fix = session.deviceLocationFix,
                           session.hasSession || context.timeIntervalSince(fix.timestamp) < 30 {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 4) {
                                    Text("Recorded")
                                    Text(fix.timestamp, style: .relative)
                                    Text("ago")
                                }.font(.caption).foregroundStyle(.secondary)
                                Text("Accuracy: about \(Int(fix.horizontalAccuracy.rounded())) m")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button {
                                    onChoose(RoutePlace(name: session.hasSession ? "Device location before spoofing" : "Device location",
                                                        coordinate: fix.coordinate))
                                } label: {
                                    Text(session.hasSession ? "Use saved device location" : "Use this location")
                                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.borderless)
                            }
                        } else if session.hasSession {
                            Text("No earlier device location was saved. Go back and search for your starting address instead.")
                                .foregroundStyle(.secondary)
                        } else if waitedForFix {
                            Text("Your phone hasn't sent a fresh location yet. Allow Location access for Shift in iPhone settings, or search for your address.")
                                .foregroundStyle(.secondary)
                        } else { ProgressView("Getting device location…") }
                    }
                }
            }
            .shiftScreen().loggedNavigationTitle("Device location").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { session.cancelDeviceLocationRefresh(); return }
                waitedForFix = false
                session.refreshDeviceLocation()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                waitedForFix = true
            }
            .onDisappear { session.cancelDeviceLocationRefresh() }
        }
    }
}

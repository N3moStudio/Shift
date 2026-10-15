import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct RoutePlannerSheet: View {
    var onDraw: () -> Void = {}
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var planner: RoutePlanner
    @EnvironmentObject private var library: TripLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchEndpoint: Endpoint?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument = GPXRouteDocument(text: "")
    @State private var showPathStop = false
    @State private var showSaveTrip = false
    @State private var tripName = ""
    @State private var savedNotice: String?
    @State private var showPractice = false
    @State private var showMapEditor = false
    @State private var showPlaceEditor = false
    @State private var confirmLiveEdit = false
    @State private var pendingEdit: SavedTrip?
    @State private var pendingEditID: UUID?
    @State private var editingSection: SectionEdit?
    @State private var liveMovementExpanded = false
    @State private var advancedExpanded = false
    private struct SectionEdit: Identifiable, Hashable {
        let id: UUID; let title: String; let choice: RouteLegChoice
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private enum Endpoint: String, Identifiable, Hashable {
        case origin, destination, stop
        var id: String { rawValue }
    }
    private var hasJourney: Bool { session.journey != nil }
    private var route: PlannedRoute? { hasJourney ? session.activeRoute : planner.selectedRoute }
    private var displayMode: TravelMode { hasJourney ? session.travelMode : planner.draftMode }
    private var displaySpeed: Double { hasJourney ? session.speedMPH(for: session.travelMode) : planner.draftSpeedMPH }
    private var displaySmooth: Bool { hasJourney ? session.smoothMovement : planner.draftSmoothMovement }

    var body: some View {
        NavigationStack {
            List {
                endpoints.shiftSettingsRows()
                if let route { routePreview(route) }
                movement.shiftSettingsRows()
                if planner.isLoading {
                    Section { ProgressView("Finding route…").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                        .listRowBackground(Color.clear)
                }
                if !hasJourney && planner.alternatives.count > 1 { alternatives.shiftSettingsRows() }
                if hasJourney {
                    stops.shiftSettingsRows()
                    arrivalOptions.shiftSettingsRows()
                } else { advancedOptions }
                if let route { routeSummary(route).shiftSettingsRows() }
                moreOptions.shiftSettingsRows()
            }
            .shiftSettingsScreen().textCase(nil)
            .loggedNavigationTitle(hasJourney ? "Your route" : "Plan a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(hasJourney ? "Done" : "Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom, spacing: 0) { routeActions }
            .onAppear {
                if !hasJourney {
                    planner.initializeDraftIfNeeded(mode: session.travelMode, speedMPH: session.speedMPH(for: session.travelMode), smoothMovement: session.smoothMovement)
                }
                if !hasJourney, planner.origin == nil, let current = session.defaultRouteOrigin {
                    planner.setOrigin(current, mode: displayMode)
                }
            }
            .navigationDestination(item: $searchEndpoint) { endpoint in
                RoutePlaceSearchSheet(title: endpoint == .origin ? "Starting point" : endpoint == .stop ? "Add stop" : "Destination",
                                      allowsDeviceOrigin: endpoint == .origin) { place in
                    if endpoint == .origin { planner.setOrigin(place, mode: displayMode) }
                    else if endpoint == .stop { planner.addWaypoint(place, mode: displayMode, speedMPH: displaySpeed) }
                    else { planner.setDestination(place, defaultOrigin: session.defaultRouteOrigin, mode: displayMode) }
                }
            }
            .navigationDestination(isPresented: $showPractice) {
                if let route { RoutePracticeSheet(route: route, mode: displayMode, speed: (displaySpeed * 0.44704)) }
            }
            .loggedConfirmationDialog("Edit this route?", isPresented: $confirmLiveEdit, titleVisibility: .visible) {
                Button("Hold location and edit") {
                    guard let route, !session.isBusy else { return }
                    pendingEditID = session.activeSavedTripID
                    pendingEdit = route.savedTrip(name: route.name, mode: displayMode, speed: displaySpeed, smooth: displaySmooth, arrival: session.arrivalChoice)
                    session.stopRoute()
                    finishLiveEditIfReady()
                }
            } message: {
                Text("This ends travel and holds your last sent location while you edit. Show route previews the changes. Start route begins again at the chosen start.")
            }
            .onChange(of: hasJourney) { _, active in if !active { finishLiveEditIfReady() } }
            .navigationDestination(isPresented: $showPlaceEditor) {
                if let route {
                    RoutePlacesEditor(route: route, waypoints: planner.editableWaypoints) { places, savePlaces in
                        planner.applyPlaceEdits(places, mode: displayMode)
                        if savePlaces {
                            for place in places { session.addFavorite(name: place.name, coordinate: place.point.coordinate) }
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $showMapEditor) {
                if let route {
                    RouteWaypointEditor(route: route, stops: planner.editableWaypoints) { start, end, stops in
                        planner.applyMapEdit(origin: start, destination: end, stops: stops, mode: displayMode, speedMPH: displaySpeed)
                    }
                }
            }
            .navigationDestination(item: $editingSection) { item in
                RouteSectionChoiceSheet(title: item.title, choice: item.choice) { choice in
                    planner.setSectionChoice(choice, for: item.id, defaultMode: displayMode)
                }
            }
            .navigationDestination(isPresented: $showPathStop) {
                if let route {
                    AddPathStopSheet(route: route, liveRoute: hasJourney) { name, fraction, wait in
                        if hasJourney { return session.addRouteStop(routeID: route.id, name: name, fraction: fraction, wait: wait) }
                        planner.addPathStop(name: name, fraction: fraction, wait: wait)
                        return nil
                    }
                }
            }
            .loggedAlert("Save trip", isPresented: $showSaveTrip) {
                TextField("Trip name", text: $tripName)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let route, library.save(route: route, name: tripName, mode: displayMode,
                        speed: displaySpeed, smooth: displaySmooth, arrival: hasJourney ? session.arrivalChoice : planner.draftArrival, replacingID: hasJourney ? session.activeSavedTripID : planner.editingTripID) {
                        if let id = library.lastSavedID {
                            if hasJourney { session.rememberSavedTrip(id, routeID: route.id) }
                            else { planner.editingTripID = id }
                        }
                        savedNotice = "Trip saved with its place names and stops."
                    }
                }
            } message: { Text("Saves the whole path from its start, travel mode, target speed, and all stops.") }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.xml, .data]) { result in
                do {
                    let coordinates = try GPXCodec.parse(result.get())
                    planner.useCustom(coordinates, source: .gpx)
                } catch { planner.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .xml,
                          defaultFilename: "Shift-Route.gpx") { result in
                if case .failure(let error) = result { planner.error = error.localizedDescription }
            }
        }
    }

    private func finishLiveEditIfReady() {
        guard !hasJourney, let trip = pendingEdit else { return }
        pendingEdit = nil
        planner.useSaved(trip)
        planner.editingTripID = pendingEditID
        pendingEditID = nil
        showPlaceEditor = true
    }

    private var endpoints: some View {
        Section {
            if hasJourney, let route {
                endpointRow("From", name: route.origin.name, icon: "circle")
                endpointRow("To", name: route.destination.name, icon: "mappin.circle.fill")
                Button { confirmLiveEdit = true } label: { Label("Edit places & stops", systemImage: "pencil") }
                    .disabled(session.isBusy || session.routeStopping)
            } else {
                Button { searchEndpoint = .origin } label: {
                    endpointRow("From", name: planner.origin?.name ?? "Choose starting point", icon: "circle")
                }
                Button { searchEndpoint = .destination } label: {
                    endpointRow("To", name: planner.destination?.name ?? "Where to?", icon: "mappin.circle.fill")
                }
                HStack {
                    Button { planner.swap(mode: displayMode) } label: {
                        Label("Swap", systemImage: "arrow.up.arrow.down").frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(planner.origin == nil || planner.destination == nil)
                    Spacer()
                    Button { planner.rebuild(mode: displayMode) } label: {
                        Label("Refresh", systemImage: "arrow.clockwise").frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(planner.origin == nil || planner.destination == nil || planner.isLoading)
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
        } header: { Label("Places", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
    }

    private func endpointRow(_ label: String, name: String, icon: String) -> some View {
        HStack(spacing: 12) {
            ShiftRowIcon(symbol: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased()).font(.footnote.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
            }
            Spacer()
            if !hasJourney { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).contentShape(Rectangle())
    }

    private var planningCycling: Bool {
        planner.hasSectionSettings ? planner.sectionChoices.values.contains { $0.mode.routeNetwork == .cycling }
            : displayMode.routeNetwork == .cycling
    }

    @ViewBuilder private var movement: some View {
        if hasJourney {
            Section {
                DisclosureGroup("Mode & speed", isExpanded: $liveMovementExpanded) {
                    RouteModeMenu()
                    MovementSpeedControl()
                }
            }
        } else {
            Section {
                if planner.hasSectionSettings {
                    Label("Using optional section settings", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                    Text("Edit them in Advanced options below.").font(.caption).foregroundStyle(.secondary)
                    if planner.usesStoredPath {
                        Button {
                            planner.setSectionSettings(false, mode: displayMode, speedMPH: displaySpeed)
                        } label: {
                            Text("Turn off section settings").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TravelMode.allCases) { mode in
                                Button {
                                    planner.draftMode = mode
                                    planner.draftSpeedMPH = session.speedMPH(for: mode)
                                    planner.modeChanged(mode)
                                } label: {
                                    Label(mode.title, systemImage: mode.icon).font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14).frame(minHeight: 44)
                                        .foregroundStyle(planner.draftMode == mode ? LocusTheme.onAccent : Color.primary)
                                        .background(planner.draftMode == mode ? LocusTheme.accent : Color.primary.opacity(0.055), in: Capsule())
                                        .contentShape(Capsule())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(mode.title)
                                    .accessibilityAddTraits(planner.draftMode == mode ? .isSelected : [])
                            }
                        }.padding(.vertical, 4)
                    }.accessibilityLabel("Travel mode")
                    draftSpeedControl
                }
            } header: { Label("Travel", systemImage: displayMode.icon) }
        }
    }

    private var draftSpeedControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speed").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f mph", displaySpeed)).font(.title2.weight(.semibold)).monospacedDigit()
            }
            Slider(value: Binding(get: { planner.draftSpeedMPH }, set: { planner.draftSpeedMPH = displayMode.clampedSpeedMPH($0) }),
                   in: displayMode.speedRangeMPH, step: displayMode == .walk || displayMode == .run ? 0.1 : 1)
                .accessibilityLabel("Planned route speed in miles per hour")
            Button { planner.draftSpeedMPH = session.usualSpeedMPH(for: displayMode) } label: {
                Label(String(format: "Use usual speed · %.1f mph", session.usualSpeedMPH(for: displayMode)), systemImage: "arrow.counterclockwise")
                    .font(.caption).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var stopRows: some View {
            if hasJourney || planner.usesStoredPath {
                ForEach(route?.stops ?? []) { stop in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(stop.name)
                            Spacer()
                            Text(JourneyText.distance(stop.metres)).font(.caption).foregroundStyle(.secondary)
                            if !hasJourney {
                                Button(role: .destructive) { planner.removePathStop(stop.id) } label: { Image(systemName: "minus.circle") }
                            }
                        }
                        if hasJourney {
                            Text(stop.waitSeconds > 0 ? "Wait \(Int(stop.waitSeconds)) sec" : "Pass through")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { waitControl(id: stop.id, seconds: stop.waitSeconds) }
                    }
                }
            } else {
                ForEach(planner.waypoints) { stop in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(stop.name).lineLimit(2)
                            Spacer()
                            Menu {
                                Button("Move earlier") { planner.moveWaypoint(stop.id, offset: -1, mode: displayMode) }
                                    .disabled(planner.waypoints.first?.id == stop.id)
                                Button("Move later") { planner.moveWaypoint(stop.id, offset: 1, mode: displayMode) }
                                    .disabled(planner.waypoints.last?.id == stop.id)
                                Button("Remove", role: .destructive) { planner.removeWaypoint(stop.id, mode: displayMode) }
                            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        }
                        waitControl(id: stop.id, seconds: stop.waitSeconds)
                    }
                }
            }
            if !hasJourney {
                if planner.usesStoredPath {
                    Button { showPathStop = true } label: {
                        Label("Add pause along path", systemImage: "pause.circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                        .disabled(route == nil || (route?.stops.count ?? 0) >= 20)
                } else {
                    Button { searchEndpoint = .stop } label: {
                        Label("Add stop", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                        .disabled(planner.waypoints.count >= 8)
                }
            } else {
                if route?.stops.isEmpty == true { Text("No planned stops").foregroundStyle(.secondary) }
                Button { showPathStop = true } label: {
                    Label("Add a stop ahead", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.disabled(!session.canAddRouteStop || (route?.stops.count ?? 0) >= 20)
                Text("Choose a pause ahead on this path. The route keeps moving while you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }

    private var arrivalPicker: some View {
        Picker("At destination", selection: Binding(get: { hasJourney ? session.arrivalChoice : planner.draftArrival },
            set: { if hasJourney { session.arrivalChoice = $0 } else { planner.draftArrival = $0 } })) {
            ForEach(ArrivalChoice.allCases) { choice in Text(choice.title).tag(choice) }
        }
    }
    private var arrivalOptions: some View {
        Section { arrivalPicker } footer: { Text("Return and repeat offer a preview at arrival. The next trip starts only when you tap Start route.") }
    }

    private var stops: some View {
        Section("Stops in order") { stopRows }
            .buttonStyle(.borderless)
    }

    @ViewBuilder private var advancedOptions: some View {
        Section {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { advancedExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(LocusTheme.accent)
                    Text("Advanced options").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Spacer()
                    Text("Optional").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(advancedExpanded ? "Expanded" : "Collapsed")
        }.listRowBackground(Color.clear)
        if advancedExpanded {
            Section {
                stopRows
                Button { showPlaceEditor = true } label: {
                    Label("Edit names & places", systemImage: "pencil")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.disabled(route == nil)
                if !planner.usesStoredPath {
                    Button { showMapEditor = true } label: {
                        Label("Move places on the map", systemImage: "hand.draw")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.disabled(route == nil)
                }
            } header: { Label("Stops & places", systemImage: "mappin.and.ellipse") }
                .shiftSettingsRows().buttonStyle(.borderless).disabled(planner.isLoading)
            Section { arrivalPicker } header: { Label("When you arrive", systemImage: "flag.checkered") }
                .shiftSettingsRows().disabled(planner.isLoading)
            Section {
                Toggle("Smooth route movement", isOn: $planner.draftSmoothMovement)
                if !planner.usesStoredPath && planningCycling {
                    Toggle("Prefer walking paths", isOn: $planner.preferWalkingPaths)
                        .onChange(of: planner.preferWalkingPaths) { _, _ in planner.rebuild(mode: displayMode) }
                }
                if !planner.usesStoredPath {
                    Toggle("Different mode for each section", isOn: Binding(
                        get: { planner.hasSectionSettings },
                        set: { planner.setSectionSettings($0, mode: displayMode, speedMPH: displaySpeed) }
                    )).disabled(planner.origin == nil || planner.destination == nil)
                    if planner.hasSectionSettings {
                        ForEach(sectionRows) { row in
                            Button { editingSection = row } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.title).font(.subheadline).foregroundStyle(.primary)
                                        Label(String(format: "%@ · %.1f mph", row.choice.mode.title, row.choice.speedMPH), systemImage: row.choice.mode.icon)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }
                        }
                    }
                } else if let route, !route.travelSections.isEmpty {
                    ForEach(route.travelSections) { section in
                        Label(String(format: "%@ · %.1f mph · %@–%@", section.mode.title, section.speedMPH,
                            JourneyText.distance(section.startMetres), JourneyText.distance(section.endMetres)), systemImage: section.mode.icon)
                            .font(.caption)
                    }
                }
            } header: { Label("Movement extras", systemImage: "speedometer") }
                .shiftSettingsRows().buttonStyle(.borderless).disabled(planner.isLoading)
        }
    }

    private var sectionRows: [SectionEdit] {
        let targets = planner.waypoints.map { ($0.id, $0.name) } + [(RouteLegChoice.destinationID, planner.destination?.name ?? "Destination")]
        var from = planner.origin?.name ?? "Start"
        return targets.enumerated().map { index, target in
            let title = "\(index + 1). \(from) → \(target.1)"
            from = target.1
            let choice = planner.sectionChoices[target.0] ?? RouteLegChoice(mode: displayMode, speedMPH: displaySpeed)
            return SectionEdit(id: target.0, title: title, choice: choice)
        }
    }

    private func waitControl(id: UUID, seconds: Double) -> some View {
        Stepper(seconds > 0 ? "Wait \(Int(seconds / 60)) min" : "Pass through", value: Binding(
            get: { seconds / 60 }, set: { planner.setWait(id, seconds: $0 * 60) }
        ), in: 0...60).font(.caption)
    }

    private var alternatives: some View {
        Section("Route choices") {
            ForEach(planner.alternatives) { option in
                Button { planner.choose(option) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.id == planner.selectedID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(LocusTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(JourneyText.distance(option.distance)) · \(JourneyText.duration(option.estimate(speed: (displaySpeed * 0.44704)))) simulated")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4).frame(minHeight: 44).contentShape(Rectangle())
                }
            }
        }
    }

    private func routePreview(_ route: PlannedRoute) -> some View {
        Section {
            Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                MapPolyline(coordinates: route.coordinates).stroke(LocusTheme.accent, lineWidth: 5)
                ForEach(route.stops) { stop in
                    Marker(stop.name, systemImage: "pause.circle.fill", coordinate: route.track.point(at: stop.metres).coordinate).tint(.orange)
                }
                Marker("Start", systemImage: "circle.fill", coordinate: route.origin.coordinate).tint(.secondary)
                Marker("Finish", systemImage: "flag.checkered", coordinate: route.destination.coordinate).tint(LocusTheme.accent)
                if hasJourney, let coordinate = session.simulated {
                    Marker("Spoofed location", systemImage: displayMode.icon, coordinate: coordinate).tint(LocusTheme.accentSecondary)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControlVisibility(.hidden)
            .id(route.id)
            .frame(height: 170)
            .overlay(alignment: .topTrailing) {
                Button { showPractice = true } label: {
                    Label("Practice", systemImage: "play.fill").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Capsule())
                }.buttonStyle(.plain).locusGlass(.regular, in: Capsule())
                    .padding(10).accessibilityLabel("Practice without spoofing")
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .accessibilityLabel("Simulated route preview")
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    // Outside the scrolling list so choosing a mode never hides Show route.
    private var routeActions: some View {
        VStack(spacing: 10) {
            if hasJourney {
                RoutePlaybackControls(onStop: { dismiss() })
            } else {
                if let error = planner.error {
                    Text(error).font(.caption).foregroundStyle(LocusTheme.statusWarn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(4)
                }
                if let route {
                    if let note = route.source.playbackNote(mode: route.travelSections.first?.mode ?? displayMode) {
                        Text(note).font(.caption.weight(.medium)).foregroundStyle(LocusTheme.statusWarn)
                    }
                }
                Button(action: showRoute) {
                    Label(planner.isLoading ? "Finding route…" : "Show route", systemImage: "map")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 50).contentShape(Rectangle())
                }
                .buttonStyle(ShiftActionStyle())
                .disabled(!canShowRoute)
                Text(route == nil ? "Choose a start and destination." : "Next: tap Start route on the map.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var canShowRoute: Bool {
        guard let route else { return false }
        return !hasJourney && !planner.isLoading && route.supports(displayMode)
    }

    private func showRoute() {
        guard canShowRoute else { return }
        if planner.prepareSelectedRoute(mode: displayMode, speedMPH: displaySpeed, smoothMovement: displaySmooth) { dismiss() }
    }

    private func routeSummary(_ route: PlannedRoute) -> some View {
        Section {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Distance").font(.caption).foregroundStyle(.secondary)
                    Text(JourneyText.distance(route.distance)).font(.title3.weight(.semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Estimated time").font(.caption).foregroundStyle(.secondary)
                    Text(JourneyText.duration(route.estimate(speed: (displaySpeed * 0.44704)))).font(.title3.weight(.semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 5)
            Button {
                tripName = library.trips.first(where: { $0.id == (hasJourney ? session.activeSavedTripID : planner.editingTripID) })?.name ?? route.name
                showSaveTrip = true
            } label: {
                Label((hasJourney ? session.activeSavedTripID : planner.editingTripID) != nil ? "Save changes to trip" : "Save this trip", systemImage: "star")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.borderless)
            if let savedNotice { Text(savedNotice).font(.caption).foregroundStyle(.secondary) }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(LocusTheme.statusWarn) }
            if !route.notices.isEmpty {
                DisclosureGroup("Route notes") {
                    ForEach(Array(route.notices.enumerated()), id: \.offset) { notice in
                        Text(notice.element).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("Trip details") }
    }

    private var moreOptions: some View {
        Section {
            DisclosureGroup("More options") {
                Button {
                    onDraw()
                    dismiss()
                } label: { Label("Draw an exact path", systemImage: "pencil.tip") }
                    .disabled(hasJourney)
                Button { showImporter = true } label: { Label("Import GPX", systemImage: "square.and.arrow.down") }
                    .disabled(hasJourney)
                Button {
                    guard let route else { return }
                    exportDocument = GPXRouteDocument(text: GPXCodec.export(route.coordinates, name: route.name))
                    showExporter = true
                } label: { Label("Export selected route", systemImage: "square.and.arrow.up") }
                    .disabled(route == nil)
            }
        }
    }
}

private struct GPXRouteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

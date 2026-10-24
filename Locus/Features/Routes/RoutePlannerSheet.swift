import CoreLocation
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct RoutePlannerSheet: View {
    var onDraw: () -> Void = {}
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var preferences: SessionPreferences
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
    @State private var draftMovementExpanded = false
    @State private var editingStop: StopEdit?
    @State private var advancedExpanded = false
    private struct SectionEdit: Identifiable, Hashable {
        let id: UUID; let title: String; let choice: RouteLegChoice
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    private struct StopEdit: Identifiable {
        let id: UUID
        let name: String
        let seconds: Double
    }
    private struct TimelinePlace: Identifiable {
        let id: UUID
        let name: String
        let wait: Double?
        let metres: Double?
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
                if let route { routePreview(route) }
                routeTimeline.shiftSettingsRows()
                movement.shiftSettingsRows()
                if planner.isLoading {
                    Section { ProgressView("Finding route…").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                        .listRowBackground(Color.clear)
                }
                if !hasJourney && planner.alternatives.count > 1 { alternatives.shiftSettingsRows() }
                if hasJourney {
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
                if let route { RoutePracticeSheet(route: route, mode: displayMode, speed: SpeedConversion.metresPerSecond(mph: displaySpeed)) }
            }
            .sheet(item: $editingStop) { item in
                StopDurationSheet(name: item.name, seconds: item.seconds, stopCount: timelineStops.count) { seconds, all in
                    guard !hasJourney, !planner.isLoading else { return }
                    if all { planner.setAllWaits(seconds: seconds) }
                    else { planner.setWait(item.id, seconds: seconds) }
                }
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

    private var timelineStops: [TripWaypoint] {
        if hasJourney, let route {
            return route.stops.map { TripWaypoint(id: $0.id, name: $0.name, point: route.track.point(at: $0.metres), waitSeconds: $0.waitSeconds) }
        }
        return planner.editableWaypoints
    }

    private var timelinePlaces: [TimelinePlace] {
        [TimelinePlace(id: RoutePlacesEditor.startID,
            name: (hasJourney ? route?.origin.name : planner.origin?.name) ?? "Choose starting point", wait: nil, metres: 0)] +
        timelineStops.map { stop in
            TimelinePlace(id: stop.id, name: stop.name, wait: stop.waitSeconds,
                metres: route?.stops.first(where: { $0.id == stop.id })?.metres)
        } +
        [TimelinePlace(id: RouteLegChoice.destinationID,
            name: (hasJourney ? route?.destination.name : planner.destination?.name) ?? "Choose destination", wait: nil, metres: route?.track.length)]
    }

    private var routeTimeline: some View {
        Section {
            ForEach(Array(timelinePlaces.enumerated()), id: \.element.id) { index, place in
                VStack(alignment: .leading, spacing: 4) {
                    if index > 0 { timelineLeg(to: place, index: index) }
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(LocusTheme.onAccent)
                            .frame(width: 28, height: 28).background(LocusTheme.accent, in: Circle())
                            .padding(.top, 8).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Button { editTimelinePlace(place) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(index == 0 ? "Start" : place.wait == nil ? "Destination" : "Stop \(index)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(place.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                            }
                            .disabled(hasJourney && (session.isBusy || session.routeStopping))
                            if let seconds = place.wait {
                                if hasJourney {
                                    Label(StopDuration.label(seconds), systemImage: "clock")
                                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
                                } else {
                                    Button { editingStop = StopEdit(id: place.id, name: place.name, seconds: seconds) } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "clock")
                                            Text(seconds == 0 ? "Pass through" : "Wait \(StopDuration.label(seconds))")
                                            Image(systemName: "chevron.right").font(.caption2)
                                        }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                                    }.accessibilityLabel("Wait at \(place.name), \(StopDuration.label(seconds))")
                                }
                            }
                        }
                        if place.wait != nil && !hasJourney { timelineStopMenu(place) }
                    }
                }
                .listRowSeparator(.hidden)
            }
            HStack {
                Button {
                    if hasJourney || planner.usesStoredPath { showPathStop = true }
                    else { searchEndpoint = .stop }
                } label: {
                    Label(hasJourney ? "Add a stop ahead" : "Add stop", systemImage: "plus.circle")
                        .frame(minHeight: 44)
                }
                .disabled(hasJourney ? !session.canAddRouteStop || timelineStops.count >= 20 : timelineStops.count >= (planner.usesStoredPath ? 20 : 8))
                Spacer()
                Menu {
                    if hasJourney {
                        Button("Edit places & stops", systemImage: "pencil") { confirmLiveEdit = true }
                            .disabled(session.isBusy || session.routeStopping)
                    } else {
                        Button("Edit names & places", systemImage: "pencil") { showPlaceEditor = true }.disabled(route == nil)
                        Button("Swap start and destination", systemImage: "arrow.up.arrow.down") { planner.swap(mode: displayMode) }
                            .disabled(planner.origin == nil || planner.destination == nil)
                        Button("Refresh directions", systemImage: "arrow.clockwise") { planner.rebuild(mode: displayMode) }
                            .disabled(planner.origin == nil || planner.destination == nil)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Route place options")
            }
        } header: { Text("Route timeline") }
        .buttonStyle(.borderless)
        .disabled(!hasJourney && planner.isLoading)
    }

    private func editTimelinePlace(_ place: TimelinePlace) {
        if hasJourney { confirmLiveEdit = true }
        else if place.id == RoutePlacesEditor.startID { searchEndpoint = .origin }
        else if place.id == RouteLegChoice.destinationID { searchEndpoint = .destination }
        else if route != nil { showPlaceEditor = true }
        else if let seconds = place.wait { editingStop = StopEdit(id: place.id, name: place.name, seconds: seconds) }
    }

    private func timelineStopMenu(_ place: TimelinePlace) -> some View {
        Menu {
            if !planner.usesStoredPath {
                Button("Move earlier") { planner.moveWaypoint(place.id, offset: -1, mode: displayMode) }
                    .disabled(planner.waypoints.first?.id == place.id)
                Button("Move later") { planner.moveWaypoint(place.id, offset: 1, mode: displayMode) }
                    .disabled(planner.waypoints.last?.id == place.id)
            }
            Button("Remove stop", role: .destructive) {
                if planner.usesStoredPath { planner.removePathStop(place.id) }
                else { planner.removeWaypoint(place.id, mode: displayMode) }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("Options for \(place.name)")
    }

    private func timelineLeg(to place: TimelinePlace, index: Int) -> some View {
        let choices = timelineLegChoices(to: place, index: index)
        return HStack(spacing: 12) {
            Rectangle().fill(LocusTheme.accent.opacity(0.3)).frame(width: 2).frame(width: 28)
            Button {
                if !hasJourney, !planner.usesStoredPath, planner.hasSectionSettings {
                    editingSection = SectionEdit(id: place.id, title: "To \(place.name)", choice: choices[0])
                } else if hasJourney { liveMovementExpanded = true }
                else { draftMovementExpanded = true }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if choices.count > 1 {
                        Label("Mixed travel · \(choices.count) sections", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if let choice = choices.first {
                        Label("\(choice.mode.title) · \(preferences.speedUnit.formatted(mph: choice.speedMPH))", systemImage: choice.mode.icon)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.accessibilityHint("Edit movement settings")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func timelineLegChoices(to place: TimelinePlace, index: Int) -> [RouteLegChoice] {
        if !hasJourney, !planner.usesStoredPath, let choice = planner.sectionChoices[place.id] { return [choice] }
        if let route, let end = place.metres, let start = timelinePlaces[index - 1].metres {
            let sections = route.travelSections.filter { $0.endMetres > start && $0.startMetres < end }
            if !sections.isEmpty {
                return sections.map { RouteLegChoice(mode: $0.mode, speedMPH: $0.speedMPH) }
            }
        }
        return [RouteLegChoice(mode: displayMode, speedMPH: displaySpeed)]
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
                DisclosureGroup("Mode & speed", isExpanded: $draftMovementExpanded) {
                if planner.hasSectionSettings {
                    Label("Using optional section settings", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                    Text(planner.usesStoredPath
                        ? "This saved path keeps its section settings. Turn them off to use one mode and speed for the whole route."
                        : "Tap a travel section in the timeline to edit it. More settings are in Advanced options.")
                        .font(.caption).foregroundStyle(.secondary)
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
                }
            }
        }
    }

    private var draftSpeedControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speed").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(preferences.speedUnit.formatted(mph: displaySpeed)).font(.title2.weight(.semibold)).monospacedDigit()
            }
            SpeedSlider(mph: $planner.draftSpeedMPH, mode: displayMode)
            Button { planner.draftSpeedMPH = session.usualSpeedMPH(for: displayMode) } label: {
                Label("Use usual speed · \(preferences.speedUnit.formatted(mph: session.usualSpeedMPH(for: displayMode)))", systemImage: "arrow.counterclockwise")
                    .font(.caption).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.borderless)
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
                                        Label("\(row.choice.mode.title) · \(preferences.speedUnit.formatted(mph: row.choice.speedMPH))", systemImage: row.choice.mode.icon)
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
                        Label("\(section.mode.title) · \(preferences.speedUnit.formatted(mph: section.speedMPH)) · \(JourneyText.distance(section.startMetres))–\(JourneyText.distance(section.endMetres))", systemImage: section.mode.icon)
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

    private var alternatives: some View {
        Section("Route choices") {
            ForEach(planner.alternatives) { option in
                Button { planner.choose(option) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.id == planner.selectedID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(LocusTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(JourneyText.distance(option.distance)) · \(JourneyText.duration(option.estimate(speed: SpeedConversion.metresPerSecond(mph: displaySpeed)))) simulated")
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
                ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                    Annotation(stop.name, coordinate: route.track.point(at: stop.metres).coordinate) {
                        Text("\(index + 2)").font(.caption.weight(.bold)).foregroundStyle(LocusTheme.onAccent)
                            .frame(width: 28, height: 28).background(LocusTheme.accent, in: Circle())
                            .overlay(Circle().stroke(.background, lineWidth: 2))
                            .accessibilityLabel("Stop \(index + 1), \(stop.name)")
                    }
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
                    Label("Preview", systemImage: "play.fill").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Capsule())
                }.buttonStyle(.plain).locusGlass(.regular, in: Capsule())
                    .padding(10).accessibilityLabel("Preview without changing location")
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
                    Text(JourneyText.duration(route.estimate(speed: SpeedConversion.metresPerSecond(mph: displaySpeed)))).font(.title3.weight(.semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 5)
            let waiting = route.stops.reduce(0) { $0 + $1.waitSeconds }
            let moving = max(0, route.estimate(speed: SpeedConversion.metresPerSecond(mph: displaySpeed)) - waiting)
            Text("Travel \(JourneyText.duration(moving)) · Stops \(StopDuration.formatted(waiting))")
                .font(.caption).foregroundStyle(.secondary)
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

import Foundation
import MapKit
import SwiftUI

/// Receives an immutable route and local playback settings only. No session,
/// pairing store, location service, or location-write callback is available here.
struct RoutePracticeSheet: View {
    let route: PlannedRoute
    let mode: TravelMode
    let speed: Double
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview = RouteRehearsal()
    private var shouldPlay: Bool { scenePhase == .active && preview.isPlaying }

    var body: some View {
        ShiftEditorContainer {
            VStack(spacing: 16) {
                Label("Preview only — this moves the orange dot", systemImage: "eye")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(LocusTheme.statusWarn)
                    .padding(.horizontal)
                Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                    MapPolyline(coordinates: route.coordinates).stroke(LocusTheme.accent, lineWidth: 5)
                    Marker("Start", systemImage: "circle", coordinate: route.origin.coordinate).tint(.secondary)
                    Marker("Finish", systemImage: "flag.checkered", coordinate: route.destination.coordinate).tint(.secondary)
                    ForEach(route.stops) { stop in
                        Marker(stop.name, systemImage: "pause.circle", coordinate: route.track.point(at: stop.metres).coordinate).tint(.orange)
                    }
                    Annotation("Preview dot", coordinate: route.track.point(at: preview.metres).coordinate) {
                        Image(systemName: currentMode.icon).font(.headline).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(.orange, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                    }
                }
                .mapStyle(.standard(elevation: .flat)).mapControlVisibility(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: 18)).padding(.horizontal)
                .accessibilityLabel("Practice route with a preview dot")
                controls.padding(.horizontal)
            }
            .padding(.bottom)
            .shiftScreen().loggedNavigationTitle("Practice route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: shouldPlay) {
                guard shouldPlay else { return }
                var last = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if shouldPlay {
                        preview.advance(seconds: now - last, length: route.track.length, speed: speed,
                                        sections: route.travelSections, stops: route.stops)
                    }
                    last = now
                }
            }
            .onChange(of: scenePhase) { _, value in if value != .active { preview.isPlaying = false } }
            .onDisappear { preview.isPlaying = false }
        }
    }
    private var currentMode: TravelMode {
        RouteTravelSection.current(in: route.travelSections, at: preview.metres)?.mode ?? mode
    }
    private var controls: some View {
        VStack(spacing: 12) {
            ProgressView(value: min(1, preview.metres / route.track.length)).tint(.orange)
            HStack {
                Text(currentMode.title)
                Spacer()
                Text("\(JourneyText.distance(preview.metres)) of \(JourneyText.distance(route.track.length))")
            }.font(.caption).foregroundStyle(.secondary)
            if preview.waitingID != nil {
                HStack {
                    Text("Planned stop · \(Int(ceil(preview.waitingSeconds))) sec remaining").font(.caption)
                    Spacer()
                    Button { preview.skipWait() } label: {
                        Text("Skip wait").padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Picker("Preview speed", selection: $preview.rate) {
                Text("1×").tag(1.0); Text("10×").tag(10.0); Text("50×").tag(50.0); Text("100×").tag(100.0)
            }.pickerStyle(.segmented)
            HStack(spacing: 12) {
                Button {
                    if preview.metres >= route.track.length { preview.reset() }
                    preview.isPlaying.toggle()
                } label: {
                    Label(preview.isPlaying ? "Pause preview" : "Play preview", systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                Button { preview.reset() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .frame(minWidth: 90, minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Text("Preview speed only speeds up this demonstration. Stops and section settings are included; connection delays and smooth movement are not simulated. Any existing spoofing session continues separately.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct RouteWaypointEditor: View {
    let route: PlannedRoute
    let onSave: (RoutePoint, RoutePoint, [TripWaypoint]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: RoutePoint
    @State private var finish: RoutePoint
    @State private var stops: [TripWaypoint]
    @State private var addingStop = false
    @State private var position: MapCameraPosition = .automatic
    @State private var dragOrigin: CGPoint?
    @State private var draggingID: UUID?
    @State private var undoFrames: [Frame] = []
    private static let startID = UUID(uuidString: "A6000000-0000-0000-0000-000000000002")!
    private static let endID = RouteLegChoice.destinationID
    private struct Frame { let start: RoutePoint; let finish: RoutePoint; let stops: [TripWaypoint] }
    private struct Handle: Identifiable { let id: UUID; let label: String; let point: RoutePoint }

    init(route: PlannedRoute, stops: [TripWaypoint], onSave: @escaping (RoutePoint, RoutePoint, [TripWaypoint]) -> Void) {
        self.route = route
        self.onSave = onSave
        _start = State(initialValue: RoutePoint(route.origin.coordinate))
        _finish = State(initialValue: RoutePoint(route.destination.coordinate))
        _stops = State(initialValue: stops)
    }
    private var handles: [Handle] {
        [Handle(id: Self.startID, label: "S", point: start)]
        + stops.enumerated().map { Handle(id: $0.element.id, label: "\($0.offset + 1)", point: $0.element.point) }
        + [Handle(id: Self.endID, label: "F", point: finish)]
    }
    var body: some View {
        ShiftEditorContainer {
            VStack(spacing: 12) {
                Text(addingStop ? "Tap the map to add a stop." : "Drag S, F, or a numbered stop. Done finds new directions.")
                    .font(.subheadline).padding(.horizontal)
                MapReader { proxy in
                    Map(position: $position, interactionModes: [.pan, .zoom]) {
                        MapPolyline(coordinates: route.coordinates).stroke(.gray.opacity(0.6), lineWidth: 4)
                        MapPolyline(coordinates: handles.map { $0.point.coordinate })
                            .stroke(.orange.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                        ForEach(handles) { handle in
                            Annotation(handle.label, coordinate: handle.point.coordinate) {
                                Text(handle.label).font(.headline.monospacedDigit()).foregroundStyle(.white)
                                    .frame(width: 44, height: 44).background(LocusTheme.accent, in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 2)).contentShape(Circle())
                                    .highPriorityGesture(handleDrag(handle, proxy: proxy))
                                    .accessibilityLabel(handle.id == Self.startID ? "Drag start" : handle.id == Self.endID ? "Drag finish" : "Drag stop \(handle.label)")
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .flat)).mapControlVisibility(.hidden)
                    .onTapGesture(coordinateSpace: .named("waypointMap")) { point in
                        guard addingStop, stops.count < 8, let coordinate = proxy.convert(point, from: .named("waypointMap")) else { return }
                        remember()
                        stops.append(TripWaypoint(name: "Map stop \(stops.count + 1)", point: RoutePoint(coordinate), waitSeconds: 0))
                        addingStop = false
                    }
                    .coordinateSpace(name: "waypointMap")
                }
                .clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal)
                HStack {
                    Button { addingStop.toggle() } label: {
                        Label(addingStop ? "Cancel add" : "Add stop", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.disabled(stops.count >= 8)
                    Button { undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.disabled(undoFrames.isEmpty)
                }.buttonStyle(.borderless).padding(.horizontal)
                Text("Orange dashed lines show the order only. They are not the route. Reorder or remove stops in Advanced options after saving.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }.padding(.bottom)
            .shiftScreen().loggedNavigationTitle("Edit route on map").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let line = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
                let rect = line.boundingMapRect
                position = .rect(rect.insetBy(dx: -max(100, rect.width * 0.2), dy: -max(100, rect.height * 0.2)))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(start, finish, stops); dismiss() }
                        .disabled(draggingID != nil)
                }
            }
        }
    }
    private func remember() {
        undoFrames.append(Frame(start: start, finish: finish, stops: stops))
        if undoFrames.count > 40 { undoFrames.removeFirst() }
    }
    private func undo() {
        guard let frame = undoFrames.popLast() else { return }
        start = frame.start; finish = frame.finish; stops = frame.stops
    }
    private func handleDrag(_ handle: Handle, proxy: MapProxy) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("waypointMap"))
            .onChanged { value in
                if draggingID == nil {
                    guard let projected = proxy.convert(handle.point.coordinate, to: .named("waypointMap")) else { return }
                    remember()
                    draggingID = handle.id
                    dragOrigin = projected
                    addingStop = false
                }
                guard draggingID == handle.id, let origin = dragOrigin,
                      let coordinate = proxy.convert(CGPoint(x: origin.x + value.translation.width,
                          y: origin.y + value.translation.height), from: .named("waypointMap")) else { return }
                let point = RoutePoint(coordinate)
                guard point.isValid else { return }
                if handle.id == Self.startID { start = point }
                else if handle.id == Self.endID { finish = point }
                else if let index = stops.firstIndex(where: { $0.id == handle.id }) { stops[index].point = point }
            }
            .onEnded { _ in dragOrigin = nil; draggingID = nil }
    }
}

struct RouteSectionChoiceSheet: View {
    @EnvironmentObject private var preferences: SessionPreferences
    let title: String
    let original: RouteLegChoice
    let onSave: (RouteLegChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: TravelMode
    @State private var speed: Double
    @State private var confirmRoadChange = false

    init(title: String, choice: RouteLegChoice, onSave: @escaping (RouteLegChoice) -> Void) {
        self.title = title; original = choice; self.onSave = onSave
        _mode = State(initialValue: choice.mode); _speed = State(initialValue: choice.speedMPH)
    }
    var body: some View {
        ShiftEditorContainer {
            Form {
                Section {
                    Text(title).font(.headline)
                    Picker("Travel mode", selection: $mode) {
                        ForEach(TravelMode.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                    LabeledContent("Target speed", value: preferences.speedUnit.formatted(mph: speed))
                    SpeedSlider(mph: $speed, mode: mode)
                } footer: { Text("Only this section changes. Done recalculates directions before you can start. Bike and e-bike use the same cycling network; walking fallback stays labeled.") }
            }
            .shiftScreen().loggedNavigationTitle("Section settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if original.mode.needsRouteChoice(changingTo: mode) { confirmRoadChange = true }
                        else { save() }
                    }
                }
            }
            .onChange(of: mode) { _, new in speed = new.defaultSpeedMPH }
            .loggedConfirmationDialog("Find matching directions?", isPresented: $confirmRoadChange, titleVisibility: .visible) {
                Button("Recalculate this section") { save() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Changing between a car and other modes needs a different path. The old route cannot start while new directions are loading.") }
        }
        .presentationDetents([.medium, .large])
    }
    private func save() { onSave(RouteLegChoice(mode: mode, speedMPH: mode.clampedSpeedMPH(speed))); dismiss() }
}

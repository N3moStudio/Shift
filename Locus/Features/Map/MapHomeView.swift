import MapKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct MapHomeView: View {
    var isVisible = true
    @Binding var incomingPlace: RoutePlace?
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var planner: RoutePlanner
    @EnvironmentObject private var library: TripLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showSearch = false
    @State private var pendingDestination: RoutePlace?
    @State private var pendingSavedTrip: SavedTrip?
    @State private var pendingPin: RoutePlace?
    @State private var showPathEditor = false
    @State private var sketchReady = false
    @State private var drawingCamera: MKMapCamera?
    @State private var drawing = RouteDrawing()
    @State private var drawingBeforeStroke: RouteDrawing?
    @State private var drawTool = DrawTool.points
    @State private var followMovement = true
    @State private var lastCameraUpdate = Date.distantPast
    @State private var selection: RouteSeek?
    @State private var activePolyline: MKPolyline?
    @State private var snapIndex: RouteSnapIndex?
    @State private var markerScreenPoint: CGPoint?
    @State private var sketchViewport = SketchMapViewport()
    @State private var markerGrabOffset: CGPoint?
    @State private var markerDragging = false
    @State private var mapSize = CGSize.zero
    @State private var undoVisible = false
    @State private var favoritePin: RoutePoint?
    @State private var favoriteName = ""
    @State private var pinAdjusting = false
    @State private var adjustedPin: CLLocationCoordinate2D?
    @State private var pinAdjustmentCamera: MKMapCamera?

    private var visualUpdatesEnabled: Bool {
        isVisible && scenePhase == .active && !showSearch && !showPathEditor && !planner.isDrawing
    }

    private enum DrawTool: String, CaseIterable, Identifiable {
        case points = "Tap", freehand = "Draw", pan = "Pan"
        var sketchTool: SketchMapView.Tool {
            switch self { case .points: return .points; case .freehand: return .freehand; case .pan: return .pan }
        }
        var help: String {
            switch self {
            case .points: return "Tap for exact points. Two fingers move or zoom the map."
            case .freehand: return "Draw at the dot below your finger. Two fingers move or zoom the map."
            case .pan: return "Move the map with one finger. Pinch to zoom. No points are added."
            }
        }
        var id: String { rawValue }
    }
    private var mapStyle: MapStyle {
        switch session.mapStyleIndex {
        case 1: return .hybrid(elevation: .flat)
        case 2: return .imagery(elevation: .flat)
        default: return .standard(elevation: .flat)
        }
    }
    private var displayedRoute: PlannedRoute? {
        session.journey != nil ? session.activeRoute : planner.preparedRoute?.route
    }
    private var interactionModes: MapInteractionModes {
        // A flat map keeps touch coordinates and the drawn path on one plane.
        markerDragging || pinAdjusting ? [] : [.pan, .zoom, .rotate]
    }
    private var canAdjustPin: Bool {
        session.pin != nil && session.journey == nil && planner.preparedRoute == nil && !planner.isDrawing && !session.isBusy
    }
    private var shownPin: CLLocationCoordinate2D? { adjustedPin ?? session.pin }
    private func pinStyle(at coordinate: CLLocationCoordinate2D) -> SavedPlace? {
        session.favorites.first { RoutePoint($0.coordinate).distance(to: RoutePoint(coordinate)) <= 5 }
    }

    private func pinAdjustmentGesture(_ proxy: MapProxy) -> MapPinAdjustmentGesture {
        MapPinAdjustmentGesture(enabled: canAdjustPin, pin: session.pin,
            project: { proxy.convert($0, to: .global) }, coordinate: { proxy.convert($0, from: .global) },
            onBegan: {
                pinAdjustmentCamera = sketchViewport.camera?.copy() as? MKMapCamera
                pinAdjusting = true
                followMovement = false
                DeveloperLogStore.shared.record("pin_adjustment_began")
            }, onMoved: { coordinate in
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { adjustedPin = coordinate }
            }, onEnded: { coordinate, cancelled in
                // This edits only a preview. No location command is sent here.
                if !cancelled, canAdjustPin, let coordinate { session.selectPin(coordinate) }
                adjustedPin = nil
                pinAdjusting = false
                DeveloperLogStore.shared.record("pin_adjustment_ended", ["cancelled": String(cancelled || coordinate == nil)])
            })
    }

    // Separate opaque view boundaries keep Xcode from solving the map,
    // every gesture and both overlays as one large SwiftUI expression.
    @MapContentBuilder private var mapAnnotations: some MapContent {
        if visualUpdatesEnabled { UserAnnotation() }
        if let route = displayedRoute, !planner.isDrawing {
            if let activePolyline { MapPolyline(activePolyline).stroke(LocusTheme.accent, lineWidth: 6) }
            ForEach(route.stops) { stop in
                Marker(stop.name, systemImage: "pause.circle.fill", coordinate: route.track.point(at: stop.metres).coordinate).tint(.orange)
            }
            Marker(route.destination.name, systemImage: "flag.checkered", coordinate: route.destination.coordinate).tint(LocusTheme.accent)
            if session.journey == nil {
                Marker("Route start", systemImage: "circle", coordinate: route.origin.coordinate).tint(.secondary)
            }
        }
        if let pin = shownPin, (session.pinIsPreview || (session.journey == nil && planner.preparedRoute == nil)), !planner.isDrawing {
            Marker(session.suggestedFavoriteName(for: pin), systemImage: pinStyle(at: pin)?.symbol.rawValue ?? "mappin",
                   coordinate: pin).tint(pinStyle(at: pin)?.tint.swatch ?? LocusTheme.accentSecondary)
        }
        if let simulated = session.simulated {
            Annotation("Last simulated location", coordinate: simulated) {
                Image(systemName: session.travelMode.icon)
                    .font(.headline).foregroundStyle(LocusTheme.onAccent)
                    .frame(width: 38, height: 38).background(LocusTheme.accent, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 3)
            }
        }
    }

    private var baseMap: some View {
        Map(position: $position, interactionModes: interactionModes) { mapAnnotations }
            .mapStyle(mapStyle)
            .mapControlVisibility(.hidden)
    }

    private func mapWithGestures(_ proxy: MapProxy) -> some View {
        // Native recognizer representables use gesture(_:). Their UIKit
        // delegates handle simultaneous recognition with the map's gestures.
        baseMap
            .gesture(pinTapGesture(proxy))
            .gesture(pinAdjustmentGesture(proxy))
            .gesture(routePressGesture(proxy))
    }

    private func homeMap(_ proxy: MapProxy) -> some View {
        mapWithGestures(proxy)
            .onMapCameraChange(frequency: .continuous) { context in
                mapCameraChanged(context.camera, proxy: proxy)
            }
            // Keep this overlay on the actual Map, with the same named origin
            // as the gestures and coordinate conversion.
            .overlay(alignment: .topLeading) { interactionOverlay(proxy) }
            .coordinateSpace(name: "routeMap")
            .onChange(of: selection) { (_: RouteSeek?, value: RouteSeek?) in
                routeSelectionChanged(value, proxy: proxy)
            }
    }

    private func mapCameraChanged(_ camera: MapCamera, proxy: MapProxy) {
        guard visualUpdatesEnabled else { return }
        session.updateJoystickMapHeading(camera.heading)
        updateMarkerProjection(proxy)
        sketchViewport.camera = MKMapCamera(lookingAtCenter: camera.centerCoordinate,
            fromDistance: camera.distance, pitch: camera.pitch, heading: camera.heading)
    }

    private func routeSelectionChanged(_ value: RouteSeek?, proxy: MapProxy) {
        if value == nil { markerGrabOffset = nil; markerDragging = false }
        if !markerDragging { updateMarkerProjection(proxy) }
    }

    private func pinTapGesture(_ proxy: MapProxy) -> MapPinTapGesture {
        MapPinTapGesture(enabled: session.journey == nil && !planner.isDrawing && !pinAdjusting) { nativeCoordinate, globalPoint in
            guard let coordinate = nativeCoordinate ?? proxy.convert(globalPoint, from: .global) else { return }
            followMovement = false
            DeveloperLogStore.shared.record("map_pin_input", ["projection": nativeCoordinate == nil ? "global fallback" : "native map"])
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                planner.discardPreparedRoute()
                session.selectPin(coordinate)
            }
        }
    }

    private func routePressGesture(_ proxy: MapProxy) -> RouteMapPressGesture {
        RouteMapPressGesture(enabled: session.activeRoute != nil && !planner.isDrawing, onTouchStart: {
            followMovement = false
        }, canBegin: { point in
            guard let candidate = markerCandidate(at: point, proxy: proxy) else { return false }
            return candidate.distance <= 44
        }, onPress: { point in
            markerDragging = true
            DeveloperLogStore.shared.record("route_marker_hold_began")
            placeMarker(at: point, proxy: proxy, requireNearRoute: true)
        }, onMoved: { point in
            placeMarker(at: point, proxy: proxy, requireNearRoute: false)
        }, onEnded: { point, cancelled in
            if !cancelled { placeMarker(at: point, proxy: proxy, requireNearRoute: false) }
            markerDragging = false
            refreshMarkerDeadline()
            DeveloperLogStore.shared.record("route_marker_hold_ended", ["cancelled": String(cancelled),
                "metres": selection.map { String($0.metres) } ?? "none"])
        })
    }

    private func interactionOverlay(_ proxy: MapProxy) -> some View {
        GeometryReader { geometry in
            magnifierOverlay(proxy, size: geometry.size)
            routeMarkerOverlay(proxy, size: geometry.size)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
    }

    @ViewBuilder private func magnifierOverlay(_ proxy: MapProxy, size: CGSize) -> some View {
        if pinAdjusting, let coordinate = adjustedPin,
           let point = proxy.convert(coordinate, to: .named("routeMap")) {
            PinMagnifier(coordinate: coordinate,
                distance: pinAdjustmentCamera?.centerCoordinateDistance ?? 1000,
                heading: pinAdjustmentCamera?.heading ?? 0, style: mapStyle)
                .position(magnifierPosition(near: point, size: size))
        }
    }

    private func magnifierPosition(near point: CGPoint, size: CGSize) -> CGPoint {
        let horizontalInset: CGFloat = 76
        let verticalInset: CGFloat = 86
        let verticalOffset: CGFloat = 130
        let desiredY: CGFloat = point.y > 210 ? point.y - verticalOffset : point.y + verticalOffset
        let maximumX: CGFloat = max(horizontalInset, size.width - horizontalInset)
        let maximumY: CGFloat = max(verticalInset, size.height - verticalInset)
        let x: CGFloat = min(max(horizontalInset, point.x), maximumX)
        let y: CGFloat = min(max(verticalInset, desiredY), maximumY)
        return CGPoint(x: x, y: y)
    }

    @ViewBuilder private func routeMarkerOverlay(_ proxy: MapProxy, size: CGSize) -> some View {
        if selection != nil, let point = markerScreenPoint,
           CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 14).contains(point) {
            markerView(at: point, availableSize: size, proxy: proxy)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                homeMap(proxy)
            }
            .background(Color(uiColor: .systemBackground))
            .ignoresSafeArea()
            .allowsHitTesting(!planner.isDrawing)
            if planner.isDrawing {
                SketchMapView(points: drawing.points,
                              tool: drawTool.sketchTool,
                              initialCamera: drawingCamera,
                              initialCenter: session.pin ?? session.simulated ?? session.realCoordinate,
                              mapStyleIndex: session.mapStyleIndex,
                              onPoint: { drawing.append(RoutePoint($0), spacing: 0.05) },
                              onPoints: { coordinates in
                                  var next = drawing
                                  for coordinate in coordinates { next.append(RoutePoint(coordinate), spacing: 0.05) }
                                  drawing = next
                              },
                              onStrokeBegan: { drawingBeforeStroke = drawing; drawing.beginStroke() },
                              onStrokeEnded: { drawing.endStroke(); drawingBeforeStroke = nil },
                              onStrokeCancelled: {
                                  if let before = drawingBeforeStroke { drawing = before }
                                  drawingBeforeStroke = nil
                              },
                              onCameraChanged: { sketchViewport.camera = $0 },
                              onReady: {
                                  guard planner.isDrawing else { return }
                                  withAnimation(drawingAnimation) { sketchReady = true }
                              })
                    .ignoresSafeArea()
                    // Keep a tiny visible contribution while MapKit renders its
                    // first frame; an alpha-zero map can defer rendering entirely.
                    .opacity(sketchReady ? 1 : 0.02)
                    .allowsHitTesting(sketchReady)
                    .transition(.opacity)
            }

            mapTools
        }
        .overlay(alignment: .bottom) {
            if planner.isDrawing {
                drawingControls.padding(.horizontal, 16).padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(drawingAnimation, value: planner.isDrawing)
        .loggedAlert("Save place", isPresented: Binding(get: { favoritePin != nil }, set: { if !$0 { favoritePin = nil } })) {
            TextField("Place name", text: $favoriteName)
            Button("Cancel", role: .cancel) { favoritePin = nil }
            Button("Save") {
                if let favoritePin { session.addFavorite(name: favoriteName, coordinate: favoritePin.coordinate) }
                favoritePin = nil
            }
        } message: { Text("Choose a name you will recognize in Saved and route planning.") }
        .onAppear {
            session.updateJoystickMapHeading(sketchViewport.camera?.heading ?? 0)
            session.setMapLocationNeeded(visualUpdatesEnabled)
            consumeIncomingPlace()
        }
        .onChange(of: visualUpdatesEnabled, initial: true) { _, needed in session.setMapLocationNeeded(needed) }
        .onChange(of: incomingPlace.map { RoutePoint($0.coordinate) }) { _, _ in consumeIncomingPlace() }
        .onChange(of: isVisible) { _, visible in if visible { consumeIncomingPlace() } }
        .onChange(of: canAdjustPin) { _, allowed in if !allowed { pinAdjusting = false; adjustedPin = nil } }
        .onDisappear { pinAdjusting = false; adjustedPin = nil; session.setMapLocationNeeded(false) }
        .onChange(of: session.activeRoute?.id, initial: true) { _, id in
            selection = nil
            markerGrabOffset = nil
            markerDragging = false
            snapIndex = session.activeRoute.map { RouteSnapIndex(track: $0.track) }
            if id != nil { followMovement = true; centerOnLocation() }
        }
        .onChange(of: displayedRoute?.id, initial: true) { _, id in
            activePolyline = displayedRoute.map { MKPolyline(coordinates: $0.coordinates, count: $0.coordinates.count) }
            if id != nil, session.journey == nil { previewRoute() }
        }
        .onChange(of: session.journey?.travelledMetres) { _, _ in
            guard visualUpdatesEnabled, followMovement, session.routeActive,
                  Date().timeIntervalSince(lastCameraUpdate) >= (session.lowPower ? 2 : 1) else { return }
            centerOnLocation()
        }
        .onChange(of: visualUpdatesEnabled) { _, enabled in
            if enabled, followMovement, session.routeActive { centerOnLocation() }
        }
        .onChange(of: position.positionedByUser) { _, isUser in if isUser { followMovement = false } }
        .onChange(of: drawTool) { _, _ in drawing.endStroke() }
        .task(id: selection?.expiresAt) {
            guard let current = selection else { return }
            let delay = max(0, current.expiresAt.timeIntervalSinceNow)
            do { try await Task.sleep(nanoseconds: UInt64(min(delay, 30) * 1_000_000_000)) } catch { return }
            if !markerDragging, selection?.routeID == current.routeID, selection?.expiresAt == current.expiresAt { selection = nil }
        }
        .task(id: session.jumpUndo?.expiresAt) {
            guard let undo = session.jumpUndo else { undoVisible = false; return }
            let delay = undo.expiresAt.timeIntervalSinceNow
            undoVisible = undo.isValid(routeID: session.activeRoute?.id, now: Date())
            guard delay > 0 else { return }
            do { try await Task.sleep(nanoseconds: UInt64(min(delay, RouteJumpUndo.duration) * 1_000_000_000)) } catch { return }
            if session.jumpUndo?.expiresAt == undo.expiresAt { undoVisible = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusDrawRoute)) { _ in beginDrawing() }
        .onReceive(NotificationCenter.default.publisher(for: .locusPreviewPlace)) { note in
            guard let place = note.object as? RoutePlace else { return }
            previewPlace(place)
        }
        .sheet(isPresented: $showPathEditor) {
            PathEditorSheet(title: "Edit drawing", points: drawing.points) { edited in drawing.replacePoints(edited); return nil }
        }
        .sheet(isPresented: $showSearch, onDismiss: {
            if let place = pendingPin {
                planner.discardPreparedRoute()
                session.selectPin(place.coordinate, name: place.name)
                previewPlace(place)
                pendingPin = nil
            } else if let trip = pendingSavedTrip {
                pendingSavedTrip = nil
                if session.journey == nil, !session.isBusy, let current = library.trips.first(where: { $0.id == trip.id }) {
                    planner.useSaved(current)
                }
            } else if let destination = pendingDestination {
                planner.plan(to: destination, defaultOrigin: session.defaultRouteOrigin, mode: session.travelMode)
                pendingDestination = nil
            }
        }) {
            RoutePlaceSearchSheet(title: "Where to?", onPreviewTeleport: { place in
                pendingPin = place
            }, onChooseTrip: { trip in pendingSavedTrip = trip }) { place in pendingDestination = place }
        }
    }

    private var mapTools: some View {
        VStack(spacing: 10) {
            if session.hasSession || session.status.isDropped { StatusBarView(isVisible: visualUpdatesEnabled) }
            if session.journey == nil && !planner.isDrawing {
                Button { showSearch = true } label: {
                    HStack(spacing: 12) {
                        ShiftMark().fill(LocusTheme.accent.gradient).frame(width: 26, height: 26).accessibilityHidden(true)
                        Text("Where do you want to go?").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16).locusGlass(.regular, in: Capsule())
                }.buttonStyle(.plain)
            }
            if !planner.isDrawing {
                HStack {
                    controls
                    Spacer(minLength: 8)
                    undoJumpButton
                    Button { followMovement = true; selection = nil; centerOnLocation() } label: {
                        Image(systemName: followMovement ? "location.fill" : "location").frame(width: 46, height: 46).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).locusGlass(.interactive, in: Circle())
                    .accessibilityLabel("Follow latest location")
                }
                if session.activeRoute != nil, selection == nil {
                    Text("Hold the route to place a jump marker")
                        .font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                        .locusGlass(.regular, in: Capsule()).allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 16).safeAreaPadding(.top, 8)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if session.journey != nil {
                mapButton("point.topleft.down.to.point.bottomright.curvepath", label: "Route details") { planner.isPresented = true }
            } else if planner.preparedRoute != nil {
                mapButton("point.topleft.down.to.point.bottomright.curvepath", label: "Edit prepared route") { planner.editPreparedRoute() }
            }
            mapButton("square.3.layers.3d", label: "Change map style") { session.mapStyleIndex = (session.mapStyleIndex + 1) % 3 }
            if displayedRoute != nil {
                mapButton("arrow.up.left.and.arrow.down.right", label: "Route overview") { previewRoute() }
            } else {
                mapButton("pencil.tip", label: "Draw a route") { beginDrawing() }
                if let pin = session.pin {
                    mapButton("star", label: "Save selected place") {
                        favoritePin = RoutePoint(pin)
                        favoriteName = session.suggestedFavoriteName(for: pin)
                    }
                }
            }
            if planner.preparedRoute == nil &&
                (session.pinIsPreview || (session.hasSession && session.simulated != nil &&
                    (session.journey == nil || session.routePaused || session.journey?.state == .waiting))) {
                SessionSpotNameButton()
            }
        }.padding(4).locusGlass(.regular, in: Capsule())
    }

    private func updateMarkerProjection(_ proxy: MapProxy) {
        guard let selected = selection, let route = session.activeRoute, selected.routeID == route.id else {
            if markerScreenPoint != nil { markerScreenPoint = nil }
            return
        }
        let point = proxy.convert(route.track.point(at: selected.metres).coordinate, to: .named("routeMap"))
        if markerScreenPoint != point { markerScreenPoint = point }
    }

    private func markerCandidate(at point: CGPoint, proxy: MapProxy) -> RouteScreenSnap? {
        let visibleBounds = CGRect(origin: .zero, size: mapSize).insetBy(dx: 14, dy: 14)
        guard visibleBounds.width > 0, visibleBounds.height > 0,
              let route = session.activeRoute, let snapIndex else { return nil }
        let touch = CGPoint(x: min(visibleBounds.maxX, max(visibleBounds.minX, point.x)),
                            y: min(visibleBounds.maxY, max(visibleBounds.minY, point.y)))
        guard let coordinate = proxy.convert(touch, from: .named("routeMap")) else { return nil }
        let preferred = selection?.metres ?? session.journey?.travelledMetres ?? 0
        // The index narrows a long path to a few segments. Final snapping uses
        // actual Map-projected endpoints, including its rotation and safe area.
        let segments = snapIndex.candidateSegments(near: RoutePoint(coordinate), preferredDistance: preferred).compactMap { index -> RouteScreenSegment? in
            guard let start = proxy.convert(route.track.points[index - 1].coordinate, to: .named("routeMap")),
                  let end = proxy.convert(route.track.points[index].coordinate, to: .named("routeMap")) else { return nil }
            return RouteScreenSegment(start: RouteScreenPoint(x: Double(start.x), y: Double(start.y)),
                                      end: RouteScreenPoint(x: Double(end.x), y: Double(end.y)),
                                      startMetres: route.track.cumulative[index - 1], endMetres: route.track.cumulative[index])
        }
        return RouteScreenSnap.closest(to: RouteScreenPoint(x: Double(touch.x), y: Double(touch.y)),
                                       segments: segments, preferredDistance: preferred)
    }

    private func placeMarker(at point: CGPoint, proxy: MapProxy, requireNearRoute: Bool) {
        let visibleBounds = CGRect(origin: .zero, size: mapSize).insetBy(dx: 14, dy: 14)
        guard let route = session.activeRoute, let closest = markerCandidate(at: point, proxy: proxy),
              (!requireNearRoute || closest.distance <= 44),
              let projected = proxy.convert(route.track.point(at: closest.metres).coordinate, to: .named("routeMap")),
              visibleBounds.contains(projected) else { return }
        let expiry = markerDragging ? selection?.expiresAt ?? Date().addingTimeInterval(30) : Date().addingTimeInterval(30)
        // One screen-space overlay drives both the circle and its touch target.
        // SwiftUI Map annotations can lag behind a continuously moving cursor.
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = RouteSeek(routeID: route.id, metres: closest.metres, expiresAt: expiry)
            markerScreenPoint = projected
        }
        followMovement = false
    }

    private func refreshMarkerDeadline() {
        if let selected = selection {
            selection = RouteSeek(routeID: selected.routeID, metres: selected.metres, expiresAt: Date().addingTimeInterval(30))
        }
    }

    private func jumpCircle(_ selected: RouteSeek) -> some View {
        Circle().fill(LocusTheme.accentSecondary).frame(width: 28, height: 28)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .frame(width: 48, height: 48)
            .allowsHitTesting(false)
            .accessibilityLabel("Drag route jump marker")
            .accessibilityValue("\(JourneyText.distance(selected.metres)) from route start")
            .accessibilityAction(named: "Cancel route marker") { selection = nil }
            .accessibilityAdjustableAction { direction in
                guard let route = session.activeRoute, selected.routeID == route.id else { return }
                let delta = max(10, route.track.length / 100)
                let target = min(route.track.length, max(0, selected.metres + (direction == .increment ? delta : -delta)))
                selection = RouteSeek(routeID: route.id, metres: target, expiresAt: Date().addingTimeInterval(30))
            }
    }

    private func markerView(at point: CGPoint, availableSize: CGSize, proxy: MapProxy) -> some View {
        let alongside = point.x + 144 <= availableSize.width - 12 ? point.x + 88 : point.x - 88
        let buttonX = min(max(68, alongside), max(68, availableSize.width - 68))
        let buttonY = min(max(28, point.y), max(28, availableSize.height - 28))
        return ZStack(alignment: .topLeading) {
            if let selected = selection { jumpCircle(selected).position(point) }
            // This view never moves. It receives touches only inside the marker,
            // so panning elsewhere stays with MapKit and drag coordinates do not
            // depend on the marker's changing annotation/overlay position.
            RouteMarkerTouchLayer(center: point, onBegan: { touch in
                DeveloperLogStore.shared.record("route_marker_drag_began")
                markerGrabOffset = CGPoint(x: point.x - touch.x, y: point.y - touch.y)
                markerDragging = true
                followMovement = false
                refreshMarkerDeadline()
            }, onMoved: { touch in
                let offset = markerGrabOffset ?? .zero
                placeMarker(at: CGPoint(x: touch.x + offset.x, y: touch.y + offset.y), proxy: proxy, requireNearRoute: false)
            }, onEnded: { touch, cancelled in
                DeveloperLogStore.shared.record("route_marker_drag_ended", ["cancelled": String(cancelled), "metres": selection.map { String($0.metres) } ?? "none"])
                if !cancelled {
                    let offset = markerGrabOffset ?? .zero
                    placeMarker(at: CGPoint(x: touch.x + offset.x, y: touch.y + offset.y), proxy: proxy, requireNearRoute: false)
                }
                markerGrabOffset = nil
                markerDragging = false
                refreshMarkerDeadline()
            })
            .frame(width: availableSize.width, height: availableSize.height)
            Button {
                guard !markerDragging, let current = selection else { return }
                if session.seekRoute(current, pairing: pairing) { selection = nil }
            } label: {
                Text("Teleport").font(.subheadline.weight(.semibold))
                    .frame(width: 112, height: 44).contentShape(Capsule())
            }
            .locusGlass(.interactive, in: Capsule())
            .disabled(markerDragging)
            .accessibilityLabel("Teleport to selected route point")
            .position(x: buttonX, y: buttonY)
        }
        .frame(width: availableSize.width, height: availableSize.height, alignment: .topLeading)
        .buttonStyle(.plain).foregroundStyle(.primary)
        .onDisappear {
            // A map zoom or presentation change can remove an offscreen touch
            // surface before UIKit sends its terminal gesture event.
            if markerDragging {
                markerGrabOffset = nil
                markerDragging = false
                refreshMarkerDeadline()
            }
        }
    }

    @ViewBuilder private var undoJumpButton: some View {
        if undoVisible, let undo = session.jumpUndo, undo.isValid(routeID: session.activeRoute?.id, now: Date()) {
            Button {
                session.undoRouteJump(pairing: pairing)
                selection = nil
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(.plain).locusGlass(.interactive, in: Circle())
            .disabled(!session.canUndoJump)
            .accessibilityLabel("Undo last route jump")
        }
    }

    private var drawingAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }
    private var drawingControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Draw your route").font(.headline)
                    Text(JourneyText.distance(drawing.distance)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { leaveDrawing() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Cancel drawing")
            }
            Picker("Drawing tool", selection: $drawTool) {
                ForEach(DrawTool.allCases) { tool in Text(tool.rawValue).tag(tool) }
            }.pickerStyle(.segmented)
            Text(sketchReady ? drawTool.help : "Preparing the drawing map…")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Button { drawing.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .disabled(!drawing.canUndo).accessibilityLabel("Undo drawing")
                Button { drawing.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .disabled(!drawing.canRedo).accessibilityLabel("Redo drawing")
                Menu {
                    Button("Edit points", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { drawing.endStroke(); showPathEditor = true }
                        .disabled(drawing.points.count < 2)
                    Button("Clear drawing", systemImage: "trash", role: .destructive) { drawing.clear() }
                        .disabled(drawing.points.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Drawing options")
                Spacer(minLength: 4)
                Button {
                    drawing.endStroke()
                    planner.useCustom(drawing.points.map(\.coordinate), source: .drawn)
                    if planner.error == nil { leaveDrawing() }
                    else { session.lastError = planner.error }
                } label: {
                    Text("Review route").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(ShiftActionStyle())
                    .disabled(drawing.points.count < 2 || !sketchReady)
            }.buttonStyle(.plain)
            if drawing.points.count >= RouteDrawing.pointLimit {
                Text("Point limit reached. Review the route or undo part of the drawing.").font(.caption).foregroundStyle(LocusTheme.statusWarn)
            }
        }
        .padding(16).locusGlass(.regular, in: RoundedRectangle(cornerRadius: 26))
    }

    private func consumeIncomingPlace() {
        guard isVisible, let place = incomingPlace else { return }
        incomingPlace = nil
        previewPlace(place)
    }

    private func leaveDrawing() {
        if let camera = sketchViewport.camera {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                position = .camera(MapCamera(centerCoordinate: camera.centerCoordinate,
                    distance: camera.centerCoordinateDistance, heading: camera.heading, pitch: camera.pitch))
            }
        }
        withAnimation(drawingAnimation) { planner.isDrawing = false }
        // Keep the departing stroke visible through the fade. Starting a new
        // drawing resets it after the outgoing map is no longer on screen.
        drawingBeforeStroke = nil
    }
    private func beginDrawing() {
        guard session.journey == nil, !planner.isDrawing else { return }
        drawingCamera = sketchViewport.camera?.copy() as? MKMapCamera
        sketchReady = false
        drawing = RouteDrawing()
        drawingBeforeStroke = nil
        drawTool = .points
        selection = nil
        followMovement = false
        withAnimation(drawingAnimation) { planner.isDrawing = true }
    }
    private func mapButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
    private func previewRoute() {
        guard let route = displayedRoute else { return }
        followMovement = false
        let rect = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count).boundingMapRect
        position = .rect(rect.insetBy(dx: -max(rect.size.width * 0.2, 200), dy: -max(rect.size.height * 0.3, 200)))
    }
    private func previewPlace(_ place: RoutePlace) {
        followMovement = false
        let region = MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 1600, longitudinalMeters: 1600)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { position = .region(region) }
    }
    private func centerOnLocation() {
        guard visualUpdatesEnabled, let coordinate = session.simulated ?? session.realCoordinate else { return }
        lastCameraUpdate = Date()
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
        if reduceMotion { position = .region(region) }
        else { withAnimation(.linear(duration: 0.4)) { position = .region(region) } }
    }
}

extension Notification.Name {
    static let locusPreviewPlace = Notification.Name("locus.previewPlace")
}

/// A fixed-size transparent touch surface. Moving the route cursor never moves
/// the gesture's coordinate space, and all touches outside its circle pass to MapKit.
private struct RouteMarkerTouchLayer: UIViewRepresentable {
    var center: CGPoint
    var onBegan: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: (CGPoint, Bool) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.markerCenter = center
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
    }

    static func dismantleUIView(_ view: TouchView, coordinator: ()) {
        view.onBegan = nil
        view.onMoved = nil
        view.onEnded = nil
        view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }
    }

    final class TouchView: UIView {
        var markerCenter = CGPoint.zero
        var onBegan: ((CGPoint) -> Void)?
        var onMoved: ((CGPoint) -> Void)?
        var onEnded: ((CGPoint, Bool) -> Void)?
        private var multiTouchCancelled = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
            press.minimumPressDuration = 0
            press.allowableMovement = CGFloat.greatestFiniteMagnitude
            press.numberOfTouchesRequired = 1
            press.cancelsTouchesInView = true
            press.delaysTouchesBegan = false
            press.delaysTouchesEnded = false
            addGestureRecognizer(press)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.contains(point) && hypot(point.x - markerCenter.x, point.y - markerCenter.y) <= 24
        }

        @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: self)
            if recognizer.numberOfTouches > 1 {
                if !multiTouchCancelled { onEnded?(point, true); multiTouchCancelled = true }
                return
            }
            if multiTouchCancelled {
                if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed { multiTouchCancelled = false }
                return
            }
            switch recognizer.state {
            case .began: onBegan?(point)
            case .changed: onMoved?(point)
            case .ended: onEnded?(point, false)
            case .cancelled, .failed: onEnded?(point, true)
            default: break
            }
        }
    }
}

/// Capture the coordinate from the native map at first contact. The MapKit
/// view owns both the touch and its projection, so safe-area offsets cannot
/// sneak in through a surrounding SwiftUI coordinate space.
private struct MapPinTapGesture: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var onTap: (CLLocationCoordinate2D?, CGPoint) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> PinTapRecognizer {
        let tap = PinTapRecognizer()
        tap.numberOfTouchesRequired = 1
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        tap.isEnabled = enabled
        return tap
    }
    func updateUIGestureRecognizer(_ tap: PinTapRecognizer, context: Context) {
        if tap.isEnabled != enabled { tap.isEnabled = enabled }
    }
    func handleUIGestureRecognizerAction(_ tap: PinTapRecognizer, context: Context) {
        guard enabled, tap.state == .ended else { return }
        onTap(tap.coordinate, context.converter.location(in: .global))
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let candidate = view {
                if candidate is UIControl { return false }
                if candidate is MKMapView { break }
                view = candidate.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
    final class PinTapRecognizer: UITapGestureRecognizer {
        private(set) var coordinate: CLLocationCoordinate2D?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            coordinate = nil
            if touches.count == 1, let touch = touches.first {
                var ancestor = touch.view
                while let view = ancestor {
                    if let map = view as? MKMapView {
                        let point = touch.location(in: map)
                        let value = map.convert(point, toCoordinateFrom: map)
                        if map.bounds.contains(point), CLLocationCoordinate2DIsValid(value) { coordinate = value }
                        break
                    }
                    ancestor = view.superview
                }
            }
            super.touchesBegan(touches, with: event)
        }
        override func reset() { super.reset(); coordinate = nil }
    }
}

/// A hold near the route owns its entire drag. A normal pan begins immediately;
/// a hold away from the route fails and leaves the map's gestures alone.
private struct RouteMapPressGesture: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var onTouchStart: () -> Void
    var canBegin: (CGPoint) -> Bool
    var onPress: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: (CGPoint, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(onTouchStart: onTouchStart, canBegin: canBegin,
                    location: { converter.location(in: .named("routeMap")) })
    }
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.3
        recognizer.allowableMovement = 18
        recognizer.numberOfTouchesRequired = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = enabled
        return recognizer
    }
    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.onTouchStart = onTouchStart
        context.coordinator.canBegin = canBegin
        context.coordinator.location = { context.converter.location(in: .named("routeMap")) }
        // Never disable this recognizer in response to its own .began event.
        if recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
    }
    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = context.converter.location(in: .named("routeMap"))
        if recognizer.numberOfTouches > 1 {
            if context.coordinator.dragging { onEnded(point, true); context.coordinator.dragging = false }
            return
        }
        switch recognizer.state {
        case .began: context.coordinator.dragging = true; onPress(point)
        case .changed: if context.coordinator.dragging { onMoved(point) }
        case .ended, .cancelled, .failed:
            if context.coordinator.dragging { onEnded(point, recognizer.state != .ended) }
            context.coordinator.dragging = false
        default: break
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTouchStart: () -> Void
        var canBegin: (CGPoint) -> Bool
        var location: () -> CGPoint
        var dragging = false
        init(onTouchStart: @escaping () -> Void, canBegin: @escaping (CGPoint) -> Bool, location: @escaping () -> CGPoint) {
            self.onTouchStart = onTouchStart; self.canBegin = canBegin; self.location = location
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            onTouchStart(); return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer.numberOfTouches == 1 && canBegin(location())
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Panning alongside a recognized hold moves the map under the cursor.
            // Pinches/rotations stay independent and cancel the single-finger edit.
            other is UIPinchGestureRecognizer || other is UIRotationGestureRecognizer
        }
    }
}

@MainActor
final class PlaceSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    var query: String = "" {
        didSet {
            completer.queryFragment = query
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = items }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

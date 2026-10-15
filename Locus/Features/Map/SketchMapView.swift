import MapKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Drawing uses a native map so a touch and its coordinate conversion have the
/// same origin. No safe-area correction is applied to point or corner taps.
struct SketchMapView: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    enum Tool: Equatable { case points, freehand, pan, edit }
    enum Outline: Equatable { case route, area }

    var points: [RoutePoint]
    var tool: Tool = .points
    var outline: Outline = .route
    var initialCamera: MKMapCamera?
    var initialCenter: CLLocationCoordinate2D?
    var mapStyleIndex = 0
    var selectedIndex: Int?
    var onPoint: (CLLocationCoordinate2D) -> Void
    var onPoints: (([CLLocationCoordinate2D]) -> Void)? = nil
    var onSelection: (Int) -> Void = { _ in }
    var onMove: (Int, CLLocationCoordinate2D) -> Void = { _, _ in }
    var onMoveEnd: (Bool) -> Void = { _ in }
    var onStrokeBegan: () -> Void = {}
    var onStrokeEnded: () -> Void = {}
    var onStrokeCancelled: () -> Void = {}
    var onCameraChanged: (MKMapCamera) -> Void = { _ in }
    var onReady: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SketchCanvas {
        let canvas = SketchCanvas()
        let map = canvas.map
        map.delegate = context.coordinator
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        // Navigation is two-finger while editing, or one-finger in Pan. These public switches let us
        // avoid changing MapKit's private gesture hierarchy or blocking zoom
        // while the one-finger drawing recognizer is active.
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = scenePhase == .active
        map.pointOfInterestFilter = .excludingAll
        context.coordinator.needsFirstUserFix = initialCamera == nil && initialCenter == nil && points.isEmpty
        context.coordinator.installGestures(on: canvas)
        context.coordinator.cursor = canvas.drawCursor
        canvas.configureViewport = { map in
            if let initialCamera {
                let camera = initialCamera.copy() as! MKMapCamera
                camera.pitch = 0
                map.setCamera(camera, animated: false)
            } else if !points.isEmpty {
                let line = MKPolyline(coordinates: points.map(\.coordinate), count: points.count)
                let rect = line.boundingMapRect
                map.setVisibleMapRect(rect.insetBy(dx: -max(100, rect.width * 0.2), dy: -max(100, rect.height * 0.2)), animated: false)
            } else if let initialCenter {
                map.setRegion(MKCoordinateRegion(center: initialCenter, latitudinalMeters: 1000, longitudinalMeters: 1000), animated: false)
            }
        }
        return canvas
    }

    func updateUIView(_ canvas: SketchCanvas, context: Context) {
        let map = canvas.map
        if map.showsUserLocation != (scenePhase == .active) { map.showsUserLocation = scenePhase == .active }
        context.coordinator.parent = self
        context.coordinator.updateTool(tool)
        let mapType: MKMapType = mapStyleIndex == 1 ? .hybrid : mapStyleIndex == 2 ? .satellite : .standard
        if map.mapType != mapType { map.mapType = mapType }
        context.coordinator.render(points, on: map)
    }

    static func dismantleUIView(_ canvas: SketchCanvas, coordinator: Coordinator) {
        coordinator.disableGestures()
        canvas.configureViewport = nil
        canvas.map.showsUserLocation = false
        canvas.map.delegate = nil
        coordinator.map = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: SketchMapView
        weak var map: MKMapView?
        weak var cursor: UIView?
        var input: SketchInputRecognizer?
        private var panGesture: UIPanGestureRecognizer?
        private var pinchGesture: UIPinchGestureRecognizer?
        var needsFirstUserFix = false
        private var renderedPoints: [RoutePoint] = []
        private var renderedOutline: Outline?
        private var dragIndex: Int?
        private var grabOffset = CGPoint.zero
        private var renderedSelection: Int?
        private var renderedTool: Tool?
        private var pointAnnotations: [Int: SketchPointAnnotation] = [:]
        private var strokeOpen = false
        private var lastStrokePoint: CGPoint?
        private var pathOverlay: SketchPathOverlay?
        private var ready = false

        init(_ parent: SketchMapView) { self.parent = parent }

        func installGestures(on canvas: SketchCanvas) {
            self.map = canvas.map
            // MapKit keeps its own tap recognizers even with scrolling and zoom
            // disabled. A sibling touch surface keeps them out of the editor's
            // gesture arena, so a stationary tap can reach our input recognizer.
            let surface = canvas.inputSurface
            let input = SketchInputRecognizer(target: self, action: #selector(handleInput(_:)))
            input.tool = parent.tool
            input.delegate = self
            input.cancelsTouchesInView = false
            input.delaysTouchesBegan = false
            input.delaysTouchesEnded = false
            input.onPointer = { [weak self] point in self?.showPointer(point) }
            surface.addGestureRecognizer(input)
            self.input = input

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.delegate = self
            surface.addGestureRecognizer(pan)
            panGesture = pan

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            surface.addGestureRecognizer(pinch)
            pinchGesture = pinch
            updateTool(parent.tool)
        }

        func disableGestures() {
            input?.isEnabled = false
            panGesture?.isEnabled = false
            pinchGesture?.isEnabled = false
        }

        func updateTool(_ tool: Tool) {
            if input?.tool != tool {
                input?.isEnabled = false
                input?.tool = tool
            }
            let enabled = tool != .pan
            if input?.isEnabled != enabled { input?.isEnabled = enabled }
            let touches = tool == .pan ? 1 : 2
            if panGesture?.minimumNumberOfTouches != touches { panGesture?.minimumNumberOfTouches = touches }
            if tool != .freehand { cursor?.isHidden = true }
        }

        private func showPointer(_ point: CGPoint?) {
            guard parent.tool == .freehand, let point, let map else { cursor?.isHidden = true; return }
            let anchor = drawPoint(point)
            cursor?.center = map.convert(anchor, to: cursor?.superview)
            cursor?.isHidden = !map.bounds.contains(anchor)
        }

        @objc private func handleInput(_ input: SketchInputRecognizer) {
            guard let map else { return }
            guard parent.tool != .pan else {
                if strokeOpen { parent.onStrokeCancelled() }
                strokeOpen = false; lastStrokePoint = nil
                return
            }
            if parent.tool == .edit {
                switch input.state {
                case .began:
                    dragIndex = nearestIndex(input.startPoint, on: map)
                    if let dragIndex {
                        let anchor = map.convert(parent.points[dragIndex].coordinate, toPointTo: map)
                        grabOffset = CGPoint(x: anchor.x - input.startPoint.x, y: anchor.y - input.startPoint.y)
                        parent.onSelection(dragIndex)
                    }
                    movePoint(input.currentPoint, on: map)
                case .changed: movePoint(input.currentPoint, on: map)
                case .ended:
                    if dragIndex != nil { movePoint(input.currentPoint, on: map); parent.onMoveEnd(false) }
                    else if let index = nearestIndex(input.currentPoint, on: map) { parent.onSelection(index) }
                    else { sendPoint(input.currentPoint, on: map) }
                    dragIndex = nil
                case .cancelled, .failed: parent.onMoveEnd(true); dragIndex = nil
                default: break
                }
                return
            }
            switch input.state {
            case .began:
                if parent.tool == .freehand {
                    strokeOpen = true
                    parent.onStrokeBegan()
                    appendStroke(input.startPoint, on: map)
                    appendStroke(input.currentPoint, on: map)
                }
            case .changed:
                if strokeOpen { appendStrokeSamples(input.samples, on: map) }
            case .ended:
                if parent.tool == .points {
                    // A tap belongs to first contact, not the small slide as a
                    // finger lifts off the glass. Freehand alone has an offset.
                    sendPoint(input.startPoint, on: map)
                } else if strokeOpen {
                    appendStroke(input.currentPoint, on: map, force: true)
                } else {
                    // A stationary touch in Draw may place a single point.
                    sendPoint(drawPoint(input.currentPoint), on: map)
                }
                finishStroke()
            case .cancelled, .failed:
                // Discard an unfinished one-finger fragment when a second
                // finger joins, including the staggered start of a pinch.
                // Lifting that finger cannot start another point or stroke.
                if strokeOpen { parent.onStrokeCancelled() }
                strokeOpen = false
                lastStrokePoint = nil
            default: break
            }
        }

        private func nearestIndex(_ touch: CGPoint, on map: MKMapView) -> Int? {
            var found: Int?
            var closest: CGFloat = 24
            for index in parent.points.indices {
                let pixel = map.convert(parent.points[index].coordinate, toPointTo: map)
                let distance = hypot(pixel.x - touch.x, pixel.y - touch.y)
                if distance < closest { closest = distance; found = index }
            }
            return found
        }
        private func movePoint(_ touch: CGPoint, on map: MKMapView) {
            guard let dragIndex else { return }
            let point = CGPoint(x: touch.x + grabOffset.x, y: touch.y + grabOffset.y)
            guard map.bounds.contains(point) else { return }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            if CLLocationCoordinate2DIsValid(coordinate) { parent.onMove(dragIndex, coordinate) }
        }
        private func drawPoint(_ point: CGPoint) -> CGPoint {
            // Deliberate freehand preview offset, independent of safe areas.
            CGPoint(x: point.x, y: point.y + 36)
        }

        private func appendStroke(_ point: CGPoint, on map: MKMapView, force: Bool = false) {
            if !force, let lastStrokePoint, hypot(point.x - lastStrokePoint.x, point.y - lastStrokePoint.y) < 2 { return }
            sendPoint(drawPoint(point), on: map)
            lastStrokePoint = point
        }

        private func appendStrokeSamples(_ samples: [CGPoint], on map: MKMapView) {
            var coordinates: [CLLocationCoordinate2D] = []
            for point in samples {
                if let lastStrokePoint, hypot(point.x - lastStrokePoint.x, point.y - lastStrokePoint.y) < 2 { continue }
                let anchor = drawPoint(point)
                guard map.bounds.contains(anchor) else { continue }
                let coordinate = map.convert(anchor, toCoordinateFrom: map)
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                coordinates.append(coordinate)
                lastStrokePoint = point
            }
            guard !coordinates.isEmpty else { return }
            if let onPoints = parent.onPoints { onPoints(coordinates) }
            else { coordinates.forEach(parent.onPoint) }
        }

        private func sendPoint(_ point: CGPoint, on map: MKMapView) {
            guard map.bounds.contains(point) else { return }
            let coordinate = map.convert(point, toCoordinateFrom: map)
            if CLLocationCoordinate2DIsValid(coordinate) { parent.onPoint(coordinate) }
        }

        private func finishStroke() {
            if strokeOpen { parent.onStrokeEnded() }
            strokeOpen = false
            lastStrokePoint = nil
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let map, pan.state == .began || pan.state == .changed else { return }
            let delta = pan.translation(in: map)
            pan.setTranslation(.zero, in: map)
            let projectedCenter = map.convert(map.centerCoordinate, toPointTo: map)
            guard let target = MapPanProjection.target(centerX: Double(projectedCenter.x), centerY: Double(projectedCenter.y),
                                                       deltaX: Double(delta.x), deltaY: Double(delta.y)) else { return }
            let coordinate = map.convert(CGPoint(x: target.x, y: target.y), toCoordinateFrom: map)
            if CLLocationCoordinate2DIsValid(coordinate) { map.setCenter(coordinate, animated: false) }
        }

        @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
            guard let map, pinch.state == .began || pinch.state == .changed,
                  pinch.scale.isFinite, pinch.scale > 0 else { return }
            let scale = Double(min(2, max(0.5, 1 / pinch.scale)))
            pinch.scale = 1
            let touch = pinch.location(in: map)
            let anchor = MKMapPoint(map.convert(touch, toCoordinateFrom: map))
            let camera = map.camera.copy() as! MKMapCamera
            camera.centerCoordinateDistance = min(40_000_000, max(10, camera.centerCoordinateDistance * scale))
            map.setCamera(camera, animated: false)
            // Keep the location under the pinch still, including on a rotated
            // map. Camera distance preserves heading and does not fit/reframe
            // a bounding rectangle during each zoom update.
            let movedAnchor = MKMapPoint(map.convert(touch, toCoordinateFrom: map))
            let center = MKMapPoint(map.centerCoordinate)
            var dx = anchor.x - movedAnchor.x
            if dx > MKMapRect.world.width / 2 { dx -= MKMapRect.world.width }
            if dx < -MKMapRect.world.width / 2 { dx += MKMapRect.world.width }
            var coordinate = MKMapPoint(x: center.x + dx, y: center.y + anchor.y - movedAnchor.y).coordinate
            coordinate.longitude = RoutePoint.longitudeDelta(coordinate.longitude)
            if CLLocationCoordinate2DIsValid(coordinate) { map.setCenter(coordinate, animated: false) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Map attribution and other native buttons remain usable.
            var candidate = touch.view
            while let view = candidate, view !== map {
                if view is UIControl { return false }
                candidate = view.superview
            }
            needsFirstUserFix = false
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Keep navigation possible when a second finger arrives midway
            // through a stroke. Input rejects/cancels that entire sequence in
            // touchesBegan; lifting a finger never resumes drawing. Ancestor
            // scroll/sheet gestures must still wait for the editor to fail.
            let ownsFirst = gestureRecognizer === input || gestureRecognizer === panGesture || gestureRecognizer === pinchGesture
            let ownsOther = other === input || other === panGesture || other === pinchGesture
            return ownsFirst && ownsOther
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === panGesture || gestureRecognizer === input || gestureRecognizer === pinchGesture,
                  let surface = gestureRecognizer.view, let otherView = other.view, otherView !== surface,
                  surface.isDescendant(of: otherView) else { return false }
            // Touches beginning on the canvas belong to the editor, including
            // a second finger arriving after a freehand stroke has begun.
            return other is UIPanGestureRecognizer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onCameraChanged(mapView.camera.copy() as! MKMapCamera)
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            revealMap()
        }
        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            // Offline tiles must not leave the editing controls disabled forever.
            revealMap()
        }
        private func revealMap() {
            guard !ready else { return }
            ready = true
            parent.onReady()
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard needsFirstUserFix, let location = userLocation.location else { return }
            needsFirstUserFix = false
            mapView.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000), animated: false)
        }

        func render(_ points: [RoutePoint], on map: MKMapView) {
            guard points != renderedPoints || parent.outline != renderedOutline || parent.selectedIndex != renderedSelection || parent.tool != renderedTool else { return }
            let oldSelection = renderedSelection
            let geometryChanged = points != renderedPoints || parent.outline != renderedOutline
            renderedSelection = parent.selectedIndex
            renderedTool = parent.tool
            renderedPoints = points
            renderedOutline = parent.outline
            if geometryChanged {
                if pathOverlay == nil {
                    let overlay = SketchPathOverlay()
                    pathOverlay = overlay
                    map.addOverlay(overlay)
                }
                if let overlay = pathOverlay {
                    overlay.replace(points: points.map { MKMapPoint($0.coordinate) }, closed: parent.outline == .area && points.count >= 3)
                    if let renderer = map.renderer(for: overlay) as? SketchPathRenderer {
                        renderer.refresh()
                    }
                }
            }
            let individualPoints = parent.outline == .area || parent.tool == .edit
            // The last-point annotation stays alive while a stroke grows.
            let indices = individualPoints ? Array(points.indices) : (points.isEmpty ? [] : [-1])
            let keptIndices = Set(indices)
            let removed = pointAnnotations.keys.filter { !keptIndices.contains($0) }
            for index in removed {
                if let annotation = pointAnnotations.removeValue(forKey: index) { map.removeAnnotation(annotation) }
            }
            for index in indices {
                let pointIndex = index == -1 ? points.count - 1 : index
                if let annotation = pointAnnotations[index] {
                    annotation.pointIndex = pointIndex
                    let next = points[pointIndex].coordinate
                    if annotation.coordinate.latitude != next.latitude || annotation.coordinate.longitude != next.longitude {
                        UIView.performWithoutAnimation { annotation.coordinate = next }
                    }
                } else {
                    let annotation = SketchPointAnnotation()
                    annotation.pointIndex = pointIndex
                    annotation.coordinate = points[pointIndex].coordinate
                    pointAnnotations[index] = annotation
                    map.addAnnotation(annotation)
                }
            }
            for index in [oldSelection, parent.selectedIndex].compactMap({ $0 }) {
                if let annotation = pointAnnotations[index], let view = map.view(for: annotation) {
                    stylePoint(view, selected: index == parent.selectedIndex)
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let path = overlay as? SketchPathOverlay { return SketchPathRenderer(overlay: path) }
            let color = UIColor(LocusTheme.accentSecondary)
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = color.withAlphaComponent(0.25)
                renderer.strokeColor = color
                renderer.lineWidth = 3
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = color
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "sketchPoint") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "sketchPoint")
            view.annotation = annotation
            view.frame.size = CGSize(width: 12, height: 12)
            view.centerOffset = .zero
            stylePoint(view, selected: (annotation as? SketchPointAnnotation)?.pointIndex == parent.selectedIndex && parent.selectedIndex != nil)
            view.layer.cornerRadius = 6
            view.layer.borderWidth = 2
            view.layer.borderColor = UIColor.white.cgColor
            view.isEnabled = false
            view.isUserInteractionEnabled = false
            view.displayPriority = .required
            return view
        }
        private func stylePoint(_ view: MKAnnotationView, selected: Bool) {
            view.backgroundColor = selected ? .systemOrange : UIColor(LocusTheme.accentSecondary)
            view.transform = selected ? CGAffineTransform(scaleX: 1.5, y: 1.5) : .identity
        }
    }
}

final class SketchPointAnnotation: MKPointAnnotation {
    var pointIndex = 0
}

/// A stable overlay avoids MapKit removing/rebuilding a polyline on every touch.
final class SketchPathOverlay: NSObject, MKOverlay {
    private let lock = NSLock()
    private var points: [MKMapPoint] = []
    private var closed = false
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
    var snapshot: (points: [MKMapPoint], closed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (points, closed)
    }
    func replace(points: [MKMapPoint], closed: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.points = points; self.closed = closed
    }
}

final class SketchPathRenderer: MKOverlayPathRenderer {
    override init(overlay: MKOverlay) {
        super.init(overlay: overlay)
        strokeColor = UIColor(LocusTheme.accentSecondary)
        lineWidth = 4
        lineCap = .round
        lineJoin = .round
        refresh()
    }
    func refresh() {
        guard let shape = overlay as? SketchPathOverlay else { return }
        fillColor = shape.snapshot.closed ? UIColor(LocusTheme.accentSecondary).withAlphaComponent(0.25) : nil
        invalidatePath()
        setNeedsDisplay()
    }
    override func createPath() {
        let path = CGMutablePath()
        if let shape = overlay as? SketchPathOverlay {
            let snapshot = shape.snapshot
            guard let first = snapshot.points.first else { self.path = path; return }
            // Keep paths that cross the date line on adjacent world edges,
            // rather than drawing a line across the entire map.
            let world = MKMapRect.world.width
            var unwrapped = [first]
            for point in snapshot.points.dropFirst() {
                let previous = unwrapped[unwrapped.count - 1]
                var x = point.x
                x += ((previous.x - x) / world).rounded() * world
                unwrapped.append(MKMapPoint(x: x, y: point.y))
            }
            var shifts: [Double] = [0]
            if unwrapped.contains(where: { $0.x < 0 }) { shifts.append(world) }
            if unwrapped.contains(where: { $0.x > world }) { shifts.append(-world) }
            for shift in shifts {
                path.move(to: point(for: MKMapPoint(x: first.x + shift, y: first.y)))
                for point in unwrapped.dropFirst() {
                    path.addLine(to: self.point(for: MKMapPoint(x: point.x + shift, y: point.y)))
                }
                if snapshot.closed { path.closeSubpath() }
            }
        }
        self.path = path
    }
}

/// The container owns layout; the map itself is an ordinary MKMapView.
final class SketchCanvas: UIView {
    let map = MKMapView()
    let inputSurface = SketchInputSurface()
    let drawCursor = UIImageView(image: UIImage(systemName: "smallcircle.filled.circle"))
    var configureViewport: ((MKMapView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(map)
        inputSurface.map = map
        inputSurface.isMultipleTouchEnabled = true
        addSubview(inputSurface)
        clipsToBounds = true
        drawCursor.frame.size = CGSize(width: 24, height: 24)
        drawCursor.tintColor = UIColor(LocusTheme.accentSecondary)
        drawCursor.backgroundColor = .systemBackground
        drawCursor.layer.cornerRadius = 12
        drawCursor.isUserInteractionEnabled = false
        drawCursor.isAccessibilityElement = false
        drawCursor.isHidden = true
        addSubview(drawCursor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        map.frame = bounds
        inputSurface.frame = bounds
        map.layoutIfNeeded()
        guard bounds.width > 1, bounds.height > 1, let configureViewport else { return }
        self.configureViewport = nil
        // A saved area's bounds must be fitted after this map has real dimensions.
        configureViewport(map)
    }
}

/// Touches go to the editor without entering MapKit's recognizer hierarchy.
/// Leave native controls, including map attribution, available underneath.
final class SketchInputSurface: UIView {
    weak var map: MKMapView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if let map {
            var candidate = map.hitTest(convert(point, to: map), with: event)
            while let view = candidate, view !== map {
                if view is UIControl { return nil }
                candidate = view.superview
            }
        }
        return hit
    }
}

/// Cancels all one-finger input for the rest of a multitouch sequence. In
/// particular, a pinch cannot end by leaving an accidental corner behind.
final class SketchInputRecognizer: UIGestureRecognizer {
    var tool = SketchMapView.Tool.points
    var onPointer: ((CGPoint?) -> Void)?
    private(set) var startPoint = CGPoint.zero
    private(set) var currentPoint = CGPoint.zero
    private(set) var samples: [CGPoint] = []
    private var finger: UITouch?
    private var rejected = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !rejected else { return }
        guard finger == nil, touches.count == 1, let touch = touches.first else {
            rejectSequence()
            return
        }
        finger = touch
        startPoint = touch.location(in: view)
        currentPoint = startPoint
        samples = [startPoint]
        onPointer?(currentPoint)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !rejected, let finger, touches.contains(finger) else { return }
        currentPoint = finger.location(in: view)
        samples = (event.coalescedTouches(for: finger) ?? [finger]).map { $0.location(in: view) }
        onPointer?(currentPoint)
        let distance = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y)
        if tool == .points {
            if distance > 8 { rejectSequence() }
        } else if state == .possible {
            if distance >= 3 { state = .began }
        } else if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onPointer?(nil)
        guard !rejected, let finger, touches.contains(finger) else { return }
        currentPoint = finger.location(in: view)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { rejectSequence() }

    override func reset() {
        super.reset()
        onPointer?(nil)
        finger = nil
        rejected = false
        samples = []
    }

    private func rejectSequence() {
        onPointer?(nil)
        rejected = true
        state = state == .began || state == .changed ? .cancelled : .failed
    }
}

/// Keeps the last viewport without redrawing SwiftUI on every camera frame.
final class SketchMapViewport {
    var camera: MKMapCamera?
}

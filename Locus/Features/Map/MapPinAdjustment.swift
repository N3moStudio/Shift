import MapKit
import SwiftUI

/// Hold only the selected marker. Pans elsewhere stay with the main map.
struct MapPinAdjustmentGesture: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var pin: CLLocationCoordinate2D?
    var project: (CLLocationCoordinate2D) -> CGPoint?
    var coordinate: (CGPoint) -> CLLocationCoordinate2D?
    var onBegan: () -> Void
    var onMoved: (CLLocationCoordinate2D) -> Void
    var onEnded: (CLLocationCoordinate2D?, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(parent: self, location: { converter.location(in: .global) })
    }
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.28
        hold.allowableMovement = 12
        hold.numberOfTouchesRequired = 1
        hold.cancelsTouchesInView = true
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        hold.delegate = context.coordinator
        hold.isEnabled = enabled
        return hold
    }
    func updateUIGestureRecognizer(_ hold: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.location = { context.converter.location(in: .global) }
        if hold.isEnabled != enabled { hold.isEnabled = enabled }
    }
    func handleUIGestureRecognizerAction(_ hold: UILongPressGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        if hold.numberOfTouches > 1 {
            coordinator.finish(cancelled: true, hold: hold)
            return
        }
        switch hold.state {
        case .began:
            guard enabled, let pin, let anchor = coordinator.projected(pin) else { return }
            let finger = coordinator.pointer(hold)
            coordinator.offset = CGPoint(x: anchor.x - finger.x, y: anchor.y - finger.y)
            coordinator.dragging = true
            onBegan()
            onMoved(pin)
        case .changed:
            if coordinator.dragging, let point = coordinator.adjustedCoordinate(hold) { onMoved(point) }
        case .ended: coordinator.finish(cancelled: false, hold: hold)
        case .cancelled, .failed: coordinator.finish(cancelled: true, hold: hold)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MapPinAdjustmentGesture
        var location: () -> CGPoint
        weak var map: MKMapView?
        var offset = CGPoint.zero
        var dragging = false
        init(parent: MapPinAdjustmentGesture, location: @escaping () -> CGPoint) {
            self.parent = parent; self.location = location
        }
        func pointer(_ hold: UIGestureRecognizer) -> CGPoint { map.map { hold.location(in: $0) } ?? location() }
        func projected(_ pin: CLLocationCoordinate2D) -> CGPoint? {
            if let map { return map.convert(pin, toPointTo: map) }
            return parent.project(pin)
        }
        func adjustedCoordinate(_ hold: UIGestureRecognizer) -> CLLocationCoordinate2D? {
            let finger = pointer(hold)
            let adjusted = CGPoint(x: finger.x + offset.x, y: finger.y + offset.y)
            let result: CLLocationCoordinate2D?
            if let map {
                guard map.bounds.contains(adjusted) else { return nil }
                result = map.convert(adjusted, toCoordinateFrom: map)
            } else { result = parent.coordinate(adjusted) }
            guard let result, CLLocationCoordinate2DIsValid(result) else { return nil }
            return result
        }
        func finish(cancelled: Bool, hold: UIGestureRecognizer) {
            guard dragging else { return }
            dragging = false
            parent.onEnded(cancelled ? nil : adjustedCoordinate(hold), cancelled)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // A second finger cancels the edit before a pinch or another
            // control can move the map underneath an active pin adjustment.
            if dragging {
                finish(cancelled: true, hold: gestureRecognizer)
                return false
            }
            map = nil
            var candidate = touch.view
            while let view = candidate {
                if view is UIControl { return false }
                if let nativeMap = view as? MKMapView { map = nativeMap; break }
                candidate = view.superview
            }
            return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard parent.enabled, gestureRecognizer.numberOfTouches == 1,
                  let pin = parent.pin, let anchor = projected(pin) else { return false }
            let finger = pointer(gestureRecognizer)
            // MapKit marker artwork sits above its coordinate (the pointed tip).
            return CGRect(x: anchor.x - 28, y: anchor.y - 64, width: 56, height: 80).contains(finger)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPinchGestureRecognizer || other is UIRotationGestureRecognizer
        }
    }
}

/// Exists only during a hold. It is a magnified map, not a screenshot of app UI.
struct PinMagnifier: View {
    let coordinate: CLLocationCoordinate2D
    let distance: CLLocationDistance
    let heading: CLLocationDirection
    let style: MapStyle
    var body: some View {
        Map(position: .constant(.camera(MapCamera(centerCoordinate: coordinate,
            distance: max(20, distance / 4), heading: heading, pitch: 0))), interactionModes: [])
            .mapStyle(style).mapControlVisibility(.hidden)
            .frame(width: 132, height: 132)
            .overlay {
                ZStack {
                    Circle().stroke(.white, lineWidth: 5).frame(width: 12, height: 12)
                    Image(systemName: "plus").font(.system(size: 24, weight: .medium)).foregroundStyle(.black)
                }
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.95), lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

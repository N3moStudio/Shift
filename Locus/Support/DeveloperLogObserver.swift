import Combine
import Network
import SwiftUI
import UIKit

@MainActor
final class DeveloperLogObserver {
    static let shared = DeveloperLogObserver()
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var monitors: [NWPathMonitor] = []
    private var started = false

    func start(session: SpoofSession) {
        guard !started else { return }; started = true
        DeveloperLogStore.shared.record("observation_started", ["device": UIDevice.current.model])
        let names: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "app_active"),
            (UIApplication.willResignActiveNotification, "app_inactive"),
            (UIApplication.didEnterBackgroundNotification, "app_background"),
            (UIApplication.willEnterForegroundNotification, "app_foreground"),
            (UIApplication.willTerminateNotification, "termination_callback_received"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "protected_data_unavailable"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "protected_data_available"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory_warning"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal_state_changed"),
            (.NSProcessInfoPowerStateDidChange, "low_power_changed")
        ]
        for (name, event) in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DeveloperLogStore.shared.record(event, [
                    "low_power": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
                    "thermal_state": String(ProcessInfo.processInfo.thermalState.rawValue)
                ])
                DeveloperLogStore.shared.maintenance(flush: true)
            })
        }
        // Network observations never change session status or gate Stop/writes.
        // A Wi-Fi path being available is not proof of a developer connection.
        for (label, monitor) in [("default", NWPathMonitor()), ("wifi", NWPathMonitor(requiredInterfaceType: .wifi))] {
            monitor.pathUpdateHandler = { path in
                let interfaces = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other]
                    .filter { path.usesInterfaceType($0) }.map { String(describing: $0) }.joined(separator: ",")
                DeveloperLogStore.shared.record("network_path_changed", ["monitor": label,
                    "status": String(describing: path.status), "interfaces": interfaces,
                    "expensive": String(path.isExpensive), "constrained": String(path.isConstrained),
                    "meaning": "Observed path only; does not identify an Airplane Mode toggle or VPN health."])
            }
            monitor.start(queue: DispatchQueue(label: "locus.log.network.\(label)", qos: .utility))
            monitors.append(monitor)
        }
        session.$status.removeDuplicates().sink { status in
            DeveloperLogStore.shared.record("session_status", ["phase": status.phase.rawValue])
        }.store(in: &subscriptions)
        session.$lastError.removeDuplicates().sink { error in
            if let error { DeveloperLogStore.shared.record("session_warning", ["message": error]) }
        }.store(in: &subscriptions)
        session.$travelMode.removeDuplicates().sink {
            DeveloperLogStore.shared.record("travel_mode_changed", ["mode": $0.rawValue])
        }.store(in: &subscriptions)
        session.$routePaused.removeDuplicates().sink {
            DeveloperLogStore.shared.record("route_pause_changed", ["paused": String($0)])
        }.store(in: &subscriptions)
        session.$journey.map { $0?.state }.removeDuplicates().sink { state in
            DeveloperLogStore.shared.record("route_state_changed", ["state": state.map { String(describing: $0) } ?? "none"])
        }.store(in: &subscriptions)
        session.$joystickActive.removeDuplicates().sink {
            DeveloperLogStore.shared.record("joystick_changed", ["active": String($0)])
        }.store(in: &subscriptions)
    }

    func snapshot(session: SpoofSession) {
        DeveloperLogStore.shared.record("session_snapshot", ["phase": session.effectivePhase.rawValue,
            "has_session": String(session.hasSession), "route_active": String(session.routeActive),
            "route_paused": String(session.routePaused), "busy": String(session.isBusy),
            "last_accepted": session.lastConfirmedAt?.ISO8601Format() ?? "none",
            "battery_level": String(UIDevice.current.batteryLevel),
            "low_power": String(ProcessInfo.processInfo.isLowPowerModeEnabled)])
    }
}

/// Passive observation on Locus's own window. No swizzling, keyboard text,
/// accessibility labels, or touches from other apps. Never wins a gesture.
struct DeveloperTouchAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ uiView: Anchor, context: Context) {}
    static func dismantleUIView(_ uiView: Anchor, coordinator: ()) { uiView.detach() }

    final class Anchor: UIView {
        private weak var observedWindow: UIWindow?
        private var observer: PassiveTouches?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard observedWindow !== window else { return }
            detach()
            guard let window else { return }
            let recognizer = PassiveTouches(target: nil, action: nil)
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            window.addGestureRecognizer(recognizer)
            observedWindow = window; observer = recognizer
        }
        func detach() {
            if let observer { observedWindow?.removeGestureRecognizer(observer) }
            observer = nil; observedWindow = nil
        }
    }

    final class PassiveTouches: UIGestureRecognizer {
        private var active: Set<UITouch> = []
        private var start: CGPoint = .zero
        private var started = Date()
        private var maximumTouches = 0
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if active.isEmpty, let touch = touches.first {
                start = touch.location(in: view); started = Date()
                DeveloperLogStore.shared.record("touch_began", ["x": String(Int(start.x)), "y": String(Int(start.y))])
            }
            active.formUnion(touches); maximumTouches = max(maximumTouches, active.count)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }
        private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
            active.subtract(touches)
            guard active.isEmpty else { return }
            let end = touches.first?.location(in: view) ?? start
            DeveloperLogStore.shared.record(cancelled ? "touch_cancelled" : "touch_ended", [
                "x": String(Int(end.x)), "y": String(Int(end.y)), "fingers": String(maximumTouches),
                "duration_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
                "kind": hypot(end.x - start.x, end.y - start.y) < 12 ? "tap_or_hold" : "gesture"
            ])
            state = .failed
        }
        override func reset() { super.reset(); active.removeAll(); maximumTouches = 0 }
    }
}

extension View {
    func loggedNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .onAppear { DeveloperLogStore.shared.record("screen_opened", ["screen": title]) }
            .onDisappear { DeveloperLogStore.shared.record("screen_closed", ["screen": title]) }
    }

    func loggedAlert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>,
                                      @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View {
        alert(title, isPresented: isPresented, actions: actions, message: message)
            .onChange(of: isPresented.wrappedValue, initial: true) { wasShown, shown in
                guard shown || wasShown else { return }
                DeveloperLogStore.shared.record(shown ? "alert_requested" : "alert_dismissed", ["title": title])
            }
    }

    /// Match SwiftUI's actions-only alert API as well as its message variant.
    /// Both forms use the same presentation logging above.
    func loggedAlert<A: View>(_ title: String, isPresented: Binding<Bool>,
                              @ViewBuilder actions: () -> A) -> some View {
        loggedAlert(title, isPresented: isPresented, actions: actions, message: { EmptyView() })
    }

    func loggedConfirmationDialog<A: View, M: View>(_ title: String, isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility, actions: actions, message: message)
            .onChange(of: isPresented.wrappedValue, initial: true) { wasShown, shown in
                guard shown || wasShown else { return }
                DeveloperLogStore.shared.record(shown ? "dialog_requested" : "dialog_dismissed", ["title": title])
            }
    }

    func loggedConfirmationDialog<A: View>(_ title: String, isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A) -> some View {
        loggedConfirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility, actions: actions, message: { EmptyView() })
    }
}

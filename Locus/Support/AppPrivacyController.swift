import LocalAuthentication
import SwiftUI
import UIKit

@MainActor
final class AppPrivacyController: NSObject, ObservableObject {
    @Published private(set) var access: PrivacyAccessState
    @Published var error: String?
    private let preferences: SessionPreferences
    private var authenticationContext: LAContext?
    private var automaticUnlockPending = true
    private weak var contentWindow: UIWindow?
    private var coverWindow: UIWindow?
    private var originalAccessibilityHidden = false
    private var accessibilityCovered = false

    private enum AuthenticationPurpose: Sendable { case unlock, enable, disable }
    var canOpenContent: Bool { access.canOpenContent }
    var isAuthenticating: Bool { access.attemptID != nil }

    init(preferences: SessionPreferences? = nil) {
        let preferences = preferences ?? .shared
        self.preferences = preferences
        access = PrivacyAccessState(authenticationEnabled: preferences.appLockEnabled)
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidEnterBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
        if UIApplication.shared.applicationState == .active { access.becameActive() }
    }

    func attach(to window: UIWindow) {
        guard contentWindow !== window else { refreshCover(); return }
        if accessibilityCovered { contentWindow?.accessibilityElementsHidden = originalAccessibilityHidden }
        accessibilityCovered = false
        coverWindow?.isHidden = true
        contentWindow = window
        guard let scene = window.windowScene else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        let host = UIHostingController(rootView: PrivacyCoverView(controller: self))
        host.view.accessibilityViewIsModal = true
        cover.rootViewController = host
        cover.backgroundColor = UIColor(white: 0.07, alpha: 1)
        cover.isHidden = true
        coverWindow = cover
        refreshCover()
        // Present authentication only once the opaque cover belongs to a scene.
        DispatchQueue.main.async { [weak self] in self?.unlockAutomaticallyIfNeeded() }
    }

    func preferencesChanged() {
        access.setAuthenticationEnabled(preferences.appLockEnabled)
        refreshCover()
    }

    func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: didBecomeActive()
        case .inactive: willResignActive()
        case .background: didEnterBackground()
        @unknown default: willResignActive()
        }
    }

    @objc private func willResignActive() {
        // Face ID itself temporarily makes the app inactive. Keep that attempt
        // alive and cover immediately; only a real background transition locks.
        access.becameInactive()
        refreshCover()
    }
    @objc private func didBecomeActive() {
        access.becameActive()
        refreshCover()
        unlockAutomaticallyIfNeeded()
    }
    @objc private func didEnterBackground() {
        access.enteredBackground()
        automaticUnlockPending = true
        authenticationContext?.invalidate()
        authenticationContext = nil
        refreshCover()
    }
    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === contentWindow?.windowScene else { return }
        willResignActive()
    }
    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === contentWindow?.windowScene else { return }
        didBecomeActive()
    }
    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === contentWindow?.windowScene else { return }
        didEnterBackground()
    }

    private func unlockAutomaticallyIfNeeded() {
        guard coverWindow != nil, contentWindow?.windowScene?.activationState == .foregroundActive,
              automaticUnlockPending, access.isLocked, access.activity == .active else { return }
        automaticUnlockPending = false
        authenticate(for: .unlock)
    }
    func unlock() { automaticUnlockPending = false; authenticate(for: .unlock) }
    func setProtectionEnabled(_ enabled: Bool) {
        guard enabled != preferences.appLockEnabled else { return }
        authenticate(for: enabled ? .enable : .disable)
    }

    private func authenticate(for purpose: AuthenticationPurpose) {
        guard let attempt = access.beginAuthentication() else { return }
        error = nil
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var capabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &capabilityError) else {
            _ = access.finishAuthentication(attempt, success: false)
            error = "Device authentication is unavailable. Check your iPhone passcode settings and try again."
            refreshCover()
            return
        }
        authenticationContext = context
        let reason: String
        switch purpose {
        case .unlock: reason = "Unlock Shift to view your maps and saved locations."
        case .enable: reason = "Confirm your identity to protect Shift."
        case .disable: reason = "Confirm your identity to turn off Shift app protection."
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
            Task { @MainActor [weak self] in self?.authenticationFinished(attempt, success: success, purpose: purpose) }
        }
    }

    private func authenticationFinished(_ attempt: UUID, success: Bool, purpose: AuthenticationPurpose) {
        guard access.finishAuthentication(attempt, success: success) else { return }
        authenticationContext = nil
        if success {
            switch purpose {
            case .unlock: break
            case .enable:
                access.setAuthenticationEnabled(true, authenticated: true)
                preferences.appLockEnabled = true
            case .disable:
                access.setAuthenticationEnabled(false, authenticated: true)
                preferences.appLockEnabled = false
            }
            error = nil
        } else {
            error = access.isLocked ? "Shift stays locked. Tap Unlock to try again." : "App protection was not changed."
        }
        refreshCover()
    }

    private func refreshCover() {
        let covered = access.needsCover(hideInSwitcher: preferences.hideInAppSwitcher)
        if covered, !accessibilityCovered, let contentWindow {
            contentWindow.endEditing(true)
            originalAccessibilityHidden = contentWindow.accessibilityElementsHidden
            contentWindow.accessibilityElementsHidden = true
            accessibilityCovered = true
        } else if !covered, accessibilityCovered {
            contentWindow?.accessibilityElementsHidden = originalAccessibilityHidden
            accessibilityCovered = false
        }
        // A separate window covers sheets, alerts, importers, and full-screen
        // presentations without dismissing them or stopping the session.
        coverWindow?.isHidden = !covered
        if covered { coverWindow?.layoutIfNeeded() }
    }
}

private struct PrivacyCoverView: View {
    @ObservedObject var controller: AppPrivacyController
    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
            VStack(spacing: 18) {
                ShiftMark().fill(LocusTheme.accent).frame(width: 64, height: 64).accessibilityHidden(true)
                Text("Shift").font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(.white)
                ShiftSignature().foregroundStyle(.white.opacity(0.7))
                if controller.access.isLocked, controller.access.activity == .active {
                    Text("Unlock with Face ID or your device passcode.")
                        .font(.body).foregroundStyle(.white.opacity(0.75))
                    Button { controller.unlock() } label: {
                        HStack(spacing: 10) {
                            if controller.isAuthenticating { ProgressView().tint(.white) }
                            Text(controller.isAuthenticating ? "Authenticating…" : "Unlock")
                        }.font(.headline).frame(maxWidth: .infinity, minHeight: 50).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                    .disabled(controller.isAuthenticating)
                    if let error = controller.error { Text(error).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
                    Text("Locking this screen does not stop an active session.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                } else {
                    Text("App preview hidden").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                }
            }.multilineTextAlignment(.center).padding(32).frame(maxWidth: 380)
        }
    }
}

struct PrivacyWindowAnchor: UIViewRepresentable {
    let controller: AppPrivacyController
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.controller = controller
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) {
        view.controller = controller
        if let window = view.window { controller.attach(to: window) }
    }
    final class AnchorView: UIView {
        weak var controller: AppPrivacyController?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { controller?.attach(to: window) }
        }
    }
}

import SwiftUI

struct JoystickPad: View {
    var radius: CGFloat = 52
    var onChange: (CGVector) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var nudgeTask: Task<Void, Never>?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Circle()
                .frame(width: radius * 2 + 28, height: radius * 2 + 28)
                .locusGlass(.clear, in: Circle())

            Circle()
                .stroke(LocusTheme.accent.opacity(0.4), lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)

            Circle()
                .fill(LocusTheme.accent)
                .frame(width: 44, height: 44)
                .shadow(color: LocusTheme.accent.opacity(0.45), radius: 8)
                .offset(dragOffset)
        }
        .frame(width: radius * 2 + 28, height: radius * 2 + 28)
        .contentShape(Circle())
        // Measure against the stationary base, never the thumb we're moving.
        // Position relative to its center also makes touching the ring intuitive.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    nudgeTask?.cancel(); nudgeTask = nil
                    let center = radius + 14
                    let limited = clamp(CGSize(width: value.location.x - center,
                                               height: value.location.y - center), radius: radius)
                    dragOffset = limited
                    onChange(CGVector(dx: limited.width / radius, dy: limited.height / radius))
                }
                .onEnded { _ in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                    onChange(.zero)
                }
        )
        .accessibilityLabel("Movement joystick")
        .accessibilityHint("Directions follow the map on screen. Choose a direction to move briefly, or Stop movement.")
        .accessibilityRepresentation {
            VStack {
                directionButton("Move up on map", vector: CGVector(dx: 0, dy: -1))
                HStack {
                    directionButton("Move left on map", vector: CGVector(dx: -1, dy: 0))
                    Button("Stop movement") { stopMovement() }
                    directionButton("Move right on map", vector: CGVector(dx: 1, dy: 0))
                }
                directionButton("Move down on map", vector: CGVector(dx: 0, dy: 1))
            }
        }
        .onDisappear { stopMovement() }
        .onChange(of: radius) { _, _ in stopMovement() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stopMovement() } }
    }

    private func directionButton(_ title: String, vector: CGVector) -> some View {
        Button(title) {
            nudgeTask?.cancel()
            onChange(vector)
            nudgeTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                onChange(.zero)
                nudgeTask = nil
            }
        }.frame(minWidth: 44, minHeight: 44)
    }
    private func stopMovement() {
        nudgeTask?.cancel(); nudgeTask = nil; dragOffset = .zero; onChange(.zero)
    }

    private func clamp(_ translation: CGSize, radius: CGFloat) -> CGSize {
        let length = sqrt(translation.width * translation.width + translation.height * translation.height)
        guard length > radius else { return translation }
        let scale = radius / length
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}

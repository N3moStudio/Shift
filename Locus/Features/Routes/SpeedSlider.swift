import SwiftUI

struct SpeedSlider: View {
    @Binding var mph: Double
    let mode: TravelMode
    @EnvironmentObject private var preferences: SessionPreferences

    var body: some View {
        Slider(value: Binding(
            get: { preferences.speedUnit.value(fromMPH: mph) },
            set: { mph = preferences.speedUnit.selectedMPH($0, mode: mode) }
        ), in: preferences.speedUnit.range(for: mode))
        .accessibilityLabel("\(mode.title) speed in \(preferences.speedUnit.spokenName)")
        .accessibilityValue(preferences.speedUnit.formatted(mph: mph))
        .accessibilityAdjustableAction { direction in
            let step = mode == .walk || mode == .run ? 0.1 : 1.0
            let current = preferences.speedUnit.value(fromMPH: mph)
            switch direction {
            case .increment: mph = preferences.speedUnit.selectedMPH(current + step, mode: mode)
            case .decrement: mph = preferences.speedUnit.selectedMPH(current - step, mode: mode)
            @unknown default: break
            }
        }
    }
}

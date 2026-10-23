import SwiftUI

/// One-second adjustment plus direct entry, so both short and long stops are easy.
struct StopDurationControl: View {
    @Binding var seconds: Double
    @FocusState private var editing: Bool
    private var value: Binding<Double> {
        Binding(get: { seconds }, set: { seconds = StopDuration.normalized($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Wait (seconds)") {
                TextField("Seconds", value: value, format: .number.precision(.fractionLength(0)).grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 70)
                    .focused($editing)
                    .accessibilityLabel("Wait in seconds")
            }
            Stepper(StopDuration.label(seconds), value: value, in: StopDuration.range, step: 1)
                .accessibilityLabel("Adjust wait by one second")
                .accessibilityValue(StopDuration.label(seconds))
            Text("0 passes through · up to 3,600 seconds")
                .font(.caption).foregroundStyle(.secondary)
        }
        .toolbar {
            if editing {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
            }
        }
    }
}

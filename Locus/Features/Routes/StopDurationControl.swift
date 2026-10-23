import SwiftUI

/// One-second adjustment plus direct entry, so both short and long stops are easy.
struct StopDurationControl: View {
    @Binding var seconds: Double
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var editing: Bool
    private var value: Binding<Double> {
        Binding(get: { seconds }, set: { seconds = StopDuration.normalized($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 88 : 48), spacing: 8)], spacing: 8) {
                ForEach([0.0, 5, 15, 30, 60], id: \.self) { preset in
                    Button { editing = false; value.wrappedValue = preset } label: {
                        Text("\(Int(preset))")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(seconds == preset ? LocusTheme.onAccent : Color.primary)
                            .background(seconds == preset ? LocusTheme.accent : Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(preset == 0 ? "Pass through without waiting" : "Wait \(Int(preset)) seconds")
                    .accessibilityAddTraits(seconds == preset ? .isSelected : [])
                }
            }
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

/// A local draft keeps Cancel and swipe-to-dismiss from changing route stops.
struct StopDurationSheet: View {
    let name: String
    let stopCount: Int
    let onSave: (Double, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var seconds: Double

    init(name: String, seconds: Double, stopCount: Int, onSave: @escaping (Double, Bool) -> Void) {
        self.name = name
        self.stopCount = stopCount
        self.onSave = onSave
        _seconds = State(initialValue: StopDuration.normalized(seconds))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { StopDurationControl(seconds: $seconds) } header: { Text(name) }
                if stopCount > 1 {
                    Section {
                        Button("Apply to all \(stopCount) stops") { save(all: true) }
                            .frame(minHeight: 44)
                    } footer: { Text("Sets every stop in this draft to \(StopDuration.label(seconds).lowercased()).") }
                }
            }
            .shiftSettingsScreen().navigationTitle("Wait at stop").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save(all: false) } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save(all: Bool) {
        onSave(StopDuration.normalized(seconds), all)
        dismiss()
    }
}

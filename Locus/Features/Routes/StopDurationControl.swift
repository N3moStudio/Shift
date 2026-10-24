import SwiftUI

/// Native time wheels keep seconds precise without making people convert hours.
struct StopDurationControl: View {
    @Binding var seconds: Double
    @Environment(\.dynamicTypeSize) private var typeSize
    private func selection(_ component: StopDuration.Component) -> Binding<Int> {
        Binding(get: { StopDuration.value(component, in: seconds) }, set: {
            seconds = StopDuration.replacing(component, in: seconds, with: $0)
        })
    }
    private func picker(_ component: StopDuration.Component) -> some View {
        Picker(component.title, selection: selection(component)) {
            ForEach(0...component.maximum, id: \.self) { number in
                Text("\(number)").tag(number)
            }
        }
        .disabled(component != .hours && seconds >= StopDuration.range.upperBound)
        .accessibilityLabel(component.title)
        .accessibilityHint(component == .hours ? "Up to 24 hours" : "Choose hours below 24 to adjust")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(StopDuration.label(seconds)).font(.headline).monospacedDigit()
                .accessibilityLabel("Wait: \(StopDuration.label(seconds))")
            if typeSize.isAccessibilitySize {
                ForEach(StopDuration.Component.allCases, id: \.self) { component in
                    picker(component).pickerStyle(.menu).frame(minHeight: 44)
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(StopDuration.Component.allCases, id: \.self) { component in
                        VStack(spacing: 0) {
                            Text(component.title).font(.caption).foregroundStyle(.secondary)
                            picker(component).pickerStyle(.wheel).labelsHidden()
                                .frame(maxWidth: .infinity).frame(height: 132).clipped()
                                .contentShape(Rectangle())
                        }
                    }
                }
                .frame(height: 160)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 110 : 76), spacing: 8)], spacing: 8) {
                ForEach([0.0, 15, 60, 300, 3600, 86_400], id: \.self) { preset in
                    Button { seconds = preset } label: {
                        Text(preset == 0 ? "No wait" : StopDuration.label(preset))
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(seconds == preset ? LocusTheme.onAccent : Color.primary)
                            .background(seconds == preset ? LocusTheme.accent : Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(preset == 0 ? "Pass through without waiting" : "Wait \(StopDuration.label(preset))")
                    .accessibilityAddTraits(seconds == preset ? .isSelected : [])
                }
            }
            Text("No wait passes straight through. Maximum: 24 hours. At 24 hours, minutes and seconds are zero.")
                .font(.caption).foregroundStyle(.secondary)
            Text("The countdown pauses when the route is paused or interrupted.")
                .font(.caption).foregroundStyle(.secondary)
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

import SwiftUI

/// Edit a draft only. Applying geometry changes rebuilds directions before Start.
struct RoutePlacesEditor: View {
    let onSave: ([TripWaypoint], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var places: [TripWaypoint]
    @State private var savePlaces = false
    @State private var addStop = false
    static let startID = UUID(uuidString: "A6000000-0000-0000-0000-000000000002")!

    init(route: PlannedRoute, waypoints: [TripWaypoint], onSave: @escaping ([TripWaypoint], Bool) -> Void) {
        self.onSave = onSave
        _places = State(initialValue:
            [TripWaypoint(id: Self.startID, name: route.origin.name, point: RoutePoint(route.origin.coordinate), waitSeconds: 0)] + waypoints +
            [TripWaypoint(id: RouteLegChoice.destinationID, name: route.destination.name, point: RoutePoint(route.destination.coordinate), waitSeconds: 0)])
    }
    var body: some View {
        ShiftEditorContainer {
            List {
                Section {
                    ForEach($places) { $place in
                        NavigationLink {
                            RoutePlaceDetailEditor(place: $place, isStop: place.id != Self.startID && place.id != RouteLegChoice.destinationID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.id == Self.startID ? "Start" : place.id == RouteLegChoice.destinationID ? "Destination" : "Stop")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(place.name).font(.headline)
                                Text(String(format: "%.5f, %.5f", place.point.latitude, place.point.longitude))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.frame(minHeight: 50)
                        }
                        .swipeActions {
                            if place.id != Self.startID && place.id != RouteLegChoice.destinationID {
                                Button("Remove", role: .destructive) { places.removeAll { $0.id == place.id } }
                            }
                        }
                    }
                    Button { addStop = true } label: { Label("Add stop", systemImage: "plus.circle") }.disabled(places.count >= 10)
                } footer: { Text("Tap a place to change its name, location, or wait. Names stay with this trip. Moving a place or removing a stop finds new directions; names and waits alone keep the exact path.") }
                Section {
                    Toggle("Also save these places", isOn: $savePlaces)
                } footer: { Text("Adds the start, stops, and destination to Saved, or updates names at those exact saved points. Leave off for names used only in this trip. Save changes to trip afterward to keep the updated route in your library.") }
            }
            .shiftScreen().loggedNavigationTitle("Places & stops").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onSave(places, savePlaces); dismiss() }
                        .disabled(places.contains { !$0.point.isValid || $0.name.count > 120 || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
            }
            .navigationDestination(isPresented: $addStop) {
                RoutePlaceSearchSheet(title: "Add stop") { place in
                    places.insert(TripWaypoint(name: place.name, point: RoutePoint(place.coordinate)), at: max(1, places.count - 1))
                }
            }
        }
    }
}

private struct RoutePlaceDetailEditor: View {
    @Binding var place: TripWaypoint
    let isStop: Bool
    @State private var search = false
    @State private var coordinates = false
    var body: some View {
        Form {
            Section("Name in this trip") { TextField("Place name", text: $place.name) }
            Section {
                Button { search = true } label: { Label("Change location", systemImage: "magnifyingglass") }
                DisclosureGroup("Coordinates (optional)", isExpanded: $coordinates) {
                    LabeledContent("Latitude") {
                        TextField("Latitude", value: Binding(get: { place.point.latitude }, set: {
                            place.point = RoutePoint(latitude: $0, longitude: place.point.longitude)
                        }), format: .number).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Longitude") {
                        TextField("Longitude", value: Binding(get: { place.point.longitude }, set: {
                            place.point = RoutePoint(latitude: place.point.latitude, longitude: $0)
                        }), format: .number).multilineTextAlignment(.trailing)
                    }
                    if !place.point.isValid { Text("Latitude must be −90 to 90; longitude −180 to 180.").foregroundStyle(LocusTheme.statusWarn) }
                }
            }
            if isStop {
                Section("Wait here") {
                    StopDurationControl(seconds: $place.waitSeconds)
                }
            }
        }
        .shiftScreen().loggedNavigationTitle("Edit place").navigationBarTitleDisplayMode(.inline)
        .onChange(of: place.name) { _, value in if value.count > 120 { place.name = String(value.prefix(120)) } }
        .navigationDestination(isPresented: $search) {
            RoutePlaceSearchSheet(title: "Choose new location") { chosen in
                place.point = RoutePoint(chosen.coordinate)
                place.name = chosen.name
            }
        }
    }
}

import SwiftUI
import MapKit

struct PathEditorSheet: View {
    let title: String
    var area = false
    var hasStops = false
    let onSave: ([RoutePoint]) -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editCoordinates = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var history: PointEditHistory
    @State private var selected: Int?
    @State private var inserting = false
    @State private var error: String?
    init(title: String, points: [RoutePoint], area: Bool = false, hasStops: Bool = false,
         onSave: @escaping ([RoutePoint]) -> String?) {
        self.title = title; self.area = area; self.hasStops = hasStops; self.onSave = onSave
        _history = State(initialValue: PointEditHistory(points))
    }
    private var valid: Bool {
        area ? NamedArea(name: "Draft", points: history.points).isValid : RouteTrack(history.points) != nil
    }
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 12) {
                Text(inserting ? "Tap where the new point should go." : "Drag a point to move it. Use two fingers to move or zoom the map.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                SketchMapView(points: history.points, tool: .edit, outline: area ? .area : .route,
                              selectedIndex: selected, onPoint: { coordinate in
                    guard inserting, let selected, history.points.count < (area ? 200 : RouteDrawing.pointLimit) else { return }
                    var next = history.points; next.insert(RoutePoint(coordinate), at: min(next.count, selected + 1))
                    history.replace(next); self.selected = selected + 1; inserting = false
                }, onSelection: { selected = $0; inserting = false },
                   onMove: { index, coordinate in history.move(index, to: RoutePoint(coordinate)); selected = index },
                   onMoveEnd: { cancelled in history.endDrag(cancelled: cancelled) })
                .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 20)).padding(.horizontal)
                let actions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
                actions {
                    Button { history.undo(); selected = nil; inserting = false } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                        .disabled(!history.canUndo).accessibilityLabel("Undo edit")
                    Button { history.redo(); selected = nil; inserting = false } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }
                        .disabled(!history.canRedo).accessibilityLabel("Redo edit")
                    Spacer()
                    Button(inserting ? "Cancel add" : "Add after") { inserting.toggle() }.frame(minHeight: 44)
                        .disabled(selected == nil || history.points.count >= (area ? 200 : RouteDrawing.pointLimit))
                    Button("Delete", role: .destructive) {
                        if let selected { var next = history.points; next.remove(at: selected); history.replace(next) }
                        selected = nil; inserting = false
                    }.frame(minHeight: 44).disabled(selected == nil || history.points.count <= (area ? 3 : 2))
                }.buttonStyle(.borderless).padding(.horizontal)
                Stepper(value: Binding(get: { selected ?? -1 }, set: { index in
                    selected = index < 0 ? nil : index; inserting = false
                }), in: -1...max(-1, history.points.count - 1)) {
                    Text(selected.map { "Point \($0 + 1) of \(history.points.count)" } ?? "Select a point")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }.frame(minHeight: 44).padding(.horizontal)
                    .accessibilityHint("Adjust to select a route point without dragging on the map.")
                Button("Edit selected coordinates") {
                    guard let selected else { return }
                    latitude = String(history.points[selected].latitude)
                    longitude = String(history.points[selected].longitude)
                    editCoordinates = true
                }.frame(minHeight: 44).disabled(selected == nil)
                if hasStops {
                    Text("Stops, waits, and speed sections stay at the same percentage along the new path. Review their positions before starting.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                if !valid { Text(area ? "The outline must have at least 3 corners and cannot cross itself." : "Use at least two different points.").font(.footnote).foregroundStyle(LocusTheme.statusWarn) }
                if let error { Text(error).font(.footnote).foregroundStyle(LocusTheme.statusWarn).padding(.horizontal) }
            }.padding(.vertical)
            }
            .shiftScreen().loggedNavigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .loggedAlert("Edit coordinates", isPresented: $editCoordinates) {
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                Button("Cancel", role: .cancel) { }
                Button("Apply") {
                    guard let selected, let lat = Double(latitude), let lon = Double(longitude) else { error = "Enter a valid latitude and longitude."; return }
                    let point = RoutePoint(latitude: lat, longitude: lon)
                    guard point.isValid else { error = "Latitude must be −90 to 90; longitude −180 to 180."; return }
                    var next = history.points; next[selected] = point; history.replace(next); error = nil
                }
            } message: { Text("Changes the selected route point. No location is sent.") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { error = onSave(history.points); if error == nil { dismiss() } }.disabled(!valid)
                }
            }
        }
    }
}

import MapKit
import SwiftUI

struct NamedAreasView: View {
    @EnvironmentObject private var session: SpoofSession
    @State private var editor: NamedAreaDraft?
    var body: some View {
        List { NamedAreasSection(onEdit: open) }.shiftScreen().loggedNavigationTitle("Named areas")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $editor) { draft in
                NamedAreaEditor(draft: draft) { area in
                    session.replaceNamedAreas(session.namedAreas.filter { $0.id != area.id } + [area])
                }
            }
    }
    private func open(_ area: NamedArea?) {
        editor = NamedAreaDraft(area: area, center: session.pin ?? session.simulated ?? session.realCoordinate)
    }
}

struct NamedAreasSection: View {
    var search = ""
    var onEdit: (NamedArea?) -> Void
    @EnvironmentObject private var session: SpoofSession
    var body: some View {
        Section {
            Button { onEdit(nil) } label: { Label("Draw a named area", systemImage: "plus").frame(minHeight: 44) }
                .disabled(session.namedAreas.count >= 100)
            if session.namedAreas.isEmpty {
                Text("Make Home a whole area. Draw its outline and Shift uses the name while your sent location is inside.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(session.namedAreas.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { area in
                Button { onEdit(area) } label: {
                    HStack(spacing: 12) {
                        ShiftRowIcon(symbol: "square.dashed")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(area.name).foregroundStyle(.primary)
                            Text("\(area.points.count) corners").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                }
                .swipeActions { Button("Delete", role: .destructive) { session.deleteNamedArea(area) } }
            }
        } footer: {
            Text("Names change labels in Shift, including its Live Activity. They don’t rename places in Find My. A named point takes priority within 5 meters; overlapping areas use the smallest outline.")
        }
    }
}

/// Owned by the screen outside List's reusable sections. Session publications
/// can rebuild rows without replacing the presentation, draft, or camera.
@MainActor final class NamedAreaDraft: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var points: [RoutePoint]
    let center: CLLocationCoordinate2D?
    let viewport = SketchMapViewport()
    init(area: NamedArea?, center: CLLocationCoordinate2D?) {
        id = area?.id ?? UUID()
        name = area?.name ?? ""
        points = area?.points ?? []
        self.center = center
    }
    var area: NamedArea {
        NamedArea(id: id, name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)), points: points)
    }
}

struct NamedAreaEditor: View {
    @ObservedObject var draft: NamedAreaDraft
    let onSave: (NamedArea) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var editingCorners = false
    @State private var confirmDiscard = false
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 12) {
                TextField("Area name, like School", text: $draft.name).textFieldStyle(.roundedBorder).padding(.horizontal)
                Text("Map").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                Text("Tap corners around the edge. Use two fingers to move or zoom. Add at least 3 corners without crossing the outline.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                SketchMapView(points: draft.points, outline: .area,
                              initialCamera: draft.viewport.camera, initialCenter: draft.center,
                              onPoint: { coordinate in
                    guard draft.points.count < 200 else { return }
                    let point = RoutePoint(coordinate)
                    if point.isValid, draft.points.last.map({ $0.distance(to: point) > 0.2 }) ?? true { draft.points.append(point) }
                }, onCameraChanged: { draft.viewport.camera = $0.copy() as? MKMapCamera })
                .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 20)).padding(.horizontal)
                HStack {
                    Button("Edit corners") { editingCorners = true }.frame(minHeight: 44).disabled(draft.points.count < 3)
                    Button { if !draft.points.isEmpty { draft.points.removeLast() } } label: {
                        Label("Undo corner", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.disabled(draft.points.isEmpty)
                    Text("\(draft.points.count) corners").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.borderless).padding(.horizontal)
                Text("Preview only. Drawing here never moves your spoofed location.").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical)
            }
            .sheet(isPresented: $editingCorners) {
                PathEditorSheet(title: "Edit area", points: draft.points, area: true) { edited in draft.points = edited; return nil }
            }
            .shiftScreen().loggedNavigationTitle("Name an area").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft.points.isEmpty && draft.name.isEmpty { dismiss() } else { confirmDiscard = true } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if onSave(draft.area) { dismiss() }
                    }.disabled(!draft.area.isValid)
                }
            }
        }
        .interactiveDismissDisabled()
        .confirmationDialog("Discard this area edit?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep drawing", role: .cancel) { }
        }
    }
}

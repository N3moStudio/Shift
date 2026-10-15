import SwiftUI

extension SavedPlaceTint {
    var swatch: Color {
        switch self {
        case .mint: return LocusTheme.accent
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .red: return .red
        }
    }
}

struct SavedPlaceBadge: View {
    var symbol: SavedPlaceSymbol
    var tint: SavedPlaceTint
    var body: some View {
        Image(systemName: symbol.rawValue).font(.body.weight(.semibold))
            .foregroundStyle(tint.swatch).frame(width: 40, height: 40)
            .background(tint.swatch.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityHidden(true)
    }
}

struct SavedPlaceEditorSheet: View {
    let place: SavedPlace
    let onSave: (String, SavedPlaceSymbol, SavedPlaceTint) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: SavedPlaceSymbol
    @State private var tint: SavedPlaceTint
    @State private var error: String?

    init(place: SavedPlace, onSave: @escaping (String, SavedPlaceSymbol, SavedPlaceTint) -> String?) {
        self.place = place
        self.onSave = onSave
        _name = State(initialValue: PlaceLabel.isCoordinate(place.name) ? "" : place.name)
        _symbol = State(initialValue: place.symbol)
        _tint = State(initialValue: place.tint)
    }
    private var cleanedName: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        SavedPlaceBadge(symbol: symbol, tint: tint)
                        TextField("Place name", text: $name).accessibilityLabel("Place name")
                    }.frame(minHeight: 52)
                }.shiftSettingsRows()
                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                        ForEach(SavedPlaceSymbol.allCases) { item in
                            Button { symbol = item } label: {
                                Image(systemName: item.rawValue).font(.title3)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .foregroundStyle(item == symbol ? tint.swatch : .primary)
                                    .background(item == symbol ? tint.swatch.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(item == symbol ? tint.swatch : .clear, lineWidth: 2))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(item.title)
                                .accessibilityAddTraits(item == symbol ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }.shiftSettingsRows()
                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                        ForEach(SavedPlaceTint.allCases) { item in
                            Button { tint = item } label: {
                                Circle().fill(item.swatch).frame(width: 32, height: 32)
                                    .overlay { if item == tint { Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(.black) } }
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(item.title)
                                .accessibilityAddTraits(item == tint ? .isSelected : [])
                        }
                    }
                }.shiftSettingsRows()
                if let error { Section { Text(error).foregroundStyle(LocusTheme.statusWarn) }.shiftSettingsRows() }
            }
            .shiftSettingsScreen().loggedNavigationTitle("Edit place").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        error = onSave(cleanedName, symbol, tint)
                        if error == nil { dismiss() }
                    }.disabled(cleanedName.isEmpty)
                }
            }
        }
    }
}

import SwiftUI

struct RecentlyDeletedView: View {
    @ObservedObject private var bin = RecentlyDeletedStore.shared
    @EnvironmentObject private var library: TripLibrary
    @EnvironmentObject private var session: SpoofSession
    @State private var deleting: DeletedLibraryItem?
    @State private var message: String?
    var body: some View {
        List {
            Section {
                if bin.items.isEmpty { Text("Nothing recently deleted").foregroundStyle(.secondary) }
                ForEach(bin.items.filter { $0.isRetained(at: Date()) }) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(PlaceLabel.readable(item.payload.name)).font(.headline)
                        Text("\(item.payload.kind) · Expires \(item.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Restore") { restore(item) }.frame(minHeight: 44)
                            Spacer()
                            Button("Delete permanently", role: .destructive) { deleting = item }.frame(minHeight: 44)
                        }.buttonStyle(.borderless)
                    }
                }
                if let error = bin.error { Text(error).foregroundStyle(LocusTheme.statusWarn) }
            } footer: { Text("Deleted places, trips, and areas stay here for 30 days. Restoring never starts spoofing. These items are not included in exports.") }
        }
        .shiftScreen().loggedNavigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
        .onAppear { bin.prune() }
        .loggedAlert("Delete permanently?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let deleting { _ = bin.remove(deleting.id) }; deleting = nil }
        } message: { Text("This cannot be undone.") }
        .loggedAlert("Couldn't restore", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
    private func restore(_ item: DeletedLibraryItem) {
        guard item.isRetained(at: Date()) else { bin.prune(); return }
        do {
            switch item.payload {
            case .trip(let trip):
                guard !library.trips.contains(where: { $0.id == trip.id }) else { throw RestoreError.exists }
                guard try library.merge([trip]) else { message = library.error; return }
            case .place(let place):
                guard !session.favorites.contains(where: { $0.id == place.id }) else { throw RestoreError.exists }
                guard session.restoreFavorite(place) else { message = session.lastError; return }
            case .area(let area):
                guard !session.namedAreas.contains(where: { $0.id == area.id }) else { throw RestoreError.exists }
                guard session.replaceNamedAreas(session.namedAreas + [area]) else { message = session.lastError; return }
            }
            if !bin.remove(item.id) { message = "Restored. The old entry couldn't be removed from Recently Deleted; it is safe to delete that entry later." }
        } catch { message = error.localizedDescription }
    }
    private enum RestoreError: LocalizedError {
        case exists
        var errorDescription: String? { "An item with this identity is already saved. Keep it, or delete it before restoring the older version." }
    }
}

import SwiftUI
import WidgetKit

private struct LibraryEntry: TimelineEntry {
    let date: Date
    let library: WidgetLibrary
    let available: Bool
    var appearance: ShiftAppearanceSelection = ShiftWidgetAppearance.read()
}
private struct LibraryProvider: TimelineProvider {
    func placeholder(in context: Context) -> LibraryEntry {
        LibraryEntry(date: Date(), library: WidgetLibrary(items: [WidgetLibraryItem(id: UUID(), title: "Saved place", kind: "place")]), available: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (LibraryEntry) -> Void) { completion(context.isPreview ? placeholder(in: context) : read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LibraryEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(900))))
    }
    private func read() -> LibraryEntry {
        guard let folder = WidgetLibrary.containerURL,
              let data = try? Data(contentsOf: folder.appendingPathComponent(WidgetLibrary.filename)), data.count <= 16_384,
              let value = try? JSONDecoder().decode(WidgetLibrary.self, from: data), value.valid else {
            return LibraryEntry(date: Date(), library: WidgetLibrary(items: []), available: false)
        }
        return LibraryEntry(date: Date(), library: value, available: true)
    }
}
struct LocusFavoriteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LocusFavorite", provider: LibraryProvider()) { entry in
            VStack(alignment: .leading, spacing: 12) {
                ShiftWidgetBrand(design: entry.appearance.icon.design).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(entry.library.primary?.title ?? "Open Shift").font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(3)
                Text(entry.library.primary?.kind == "trip" ? "Review trip" : "Choose your pin").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { ShiftWidgetBackground(style: entry.appearance.style) }
            .widgetURL(entry.library.primary?.url ?? URL(string: "shift://session")!)
        }.configurationDisplayName("Favorite shortcut").description("Open a place or trip. You choose when to start.")
            .supportedFamilies([.systemSmall])
    }
}
struct LocusLibraryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LocusLibrary", provider: LibraryProvider()) { entry in
            LibraryWidgetView(entry: entry).containerBackground(for: .widget) { ShiftWidgetBackground(style: entry.appearance.style) }
        }.configurationDisplayName("Saved shortcuts").description("Your selected places and trips, ready to open.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
private struct LibraryWidgetView: View {
    let entry: LibraryEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShiftWidgetBrand(design: entry.appearance.icon.design).foregroundStyle(.primary)
            if entry.library.items.isEmpty {
                Link(destination: URL(string: "shift://session")!) {
                    VStack(alignment: .leading) {
                        Text("Open Shift").font(.headline)
                        Text(entry.available ? "Choose shortcuts in Settings → Home Screen widgets." : "Open the app to check widget setup.").font(.caption)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(entry.library.items.prefix(family == .systemLarge ? 4 : 2))) { item in
                    if let url = item.url {
                        Link(destination: url) {
                            Label(item.title, systemImage: item.kind == "place" ? "mappin" : "point.topleft.down.curvedto.point.bottomright.up")
                                .font(.subheadline.weight(.medium)).lineLimit(2)
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
        }.widgetURL(URL(string: "shift://session"))
    }
}

private struct ShiftWidgetBackground: View {
    let style: ShiftVisualStyle
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ShiftPalette.color(.canvas, style: style)
            .overlay(alignment: .top) { Rectangle().fill(ShiftPalette.color(.accent, style: style)).frame(height: 3) }
    }
}

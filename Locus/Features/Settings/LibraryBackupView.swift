import SwiftUI
import UniformTypeIdentifiers

struct LibraryBackupView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var library: TripLibrary
    @EnvironmentObject private var planner: RoutePlanner
    @State private var document = LibraryBackupDocument()
    @State private var exporting = false
    @State private var importing = false
    @State private var preview: LibraryBackup?
    @State private var exportSelection = Set(BackupCategory.allCases)
    @State private var importSelection: Set<BackupCategory> = []
    @State private var message: String?
    @State private var confirmImport = false
    @State private var confirmExport = false

    var body: some View {
        List {
            Section {
                categoryChoices(available: Set(BackupCategory.allCases), selection: $exportSelection)
                Button { confirmExport = true
                } label: { Label("Export backup", systemImage: "square.and.arrow.up").frame(minHeight: 44) }.disabled(exportSelection.isEmpty)
                Button { importing = true } label: {
                    Label("Import backup", systemImage: "square.and.arrow.down").frame(minHeight: 44)
                }.disabled(session.hasSession || session.isBusy)
            } header: { Text("Choose what to export") } footer: {
                Text("End your spoofing session before importing.")
            }.shiftSettingsRows()
            if let preview {
                Section("Check before importing") {
                    LabeledContent("Saved places", value: "\(preview.places.count)")
                    LabeledContent("Saved trips", value: "\(preview.trips.count)")
                    LabeledContent("Created", value: preview.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Named areas", value: "\((preview.areas ?? []).count)")
                    categoryChoices(available: preview.included, selection: $importSelection)
                    Text("Adds missing items and keeps your existing versions of saved places and trips.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Import these items") { confirmImport = true }
                        .frame(minHeight: 44).disabled(importSelection.isEmpty || session.hasSession || session.isBusy)
                    Button("Cancel preview", role: .cancel) { self.preview = nil }
                }.shiftSettingsRows()
            }
            if let message { Section { Text(message).font(.footnote) }.shiftSettingsRows() }
            Section {
                SettingsHelp(title: "What's in a backup?", lines: [
                    "Choose places, trips, settings, or all three. Saved names and folders are included.",
                    "Settings include appearance, speeds, Live Activities, history preferences, and alerts. Importing settings replaces those choices.",
                    "Pairing, helper access keys, tunnel address, app lock, recent history, and recovery points stay on this phone.",
                    "The file is readable and can contain saved locations. Nothing is uploaded automatically."
                ])
            }.shiftSettingsRows()
            Section("Other files") {
                NavigationLink { ConnectionSettingsView() } label: { Label("iPhone pairing file", systemImage: "iphone") }
                NavigationLink { FindMyChecksView() } label: { Label("Find My helper setup", systemImage: "icloud") }
                Text("GPX routes open in the route planner. Pairing files connect your iPhone; helper setup files connect Find My checks. They are separate from a library backup.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.shiftSettingsRows()
        }
        .shiftSettingsScreen().loggedNavigationTitle("Files & backups").navigationBarTitleDisplayMode(.inline)
        .loggedConfirmationDialog("Export this library?", isPresented: $confirmExport, titleVisibility: .visible) {
            Button("Export selected items") {
                do {
                        let backup = LibraryBackup(places: session.favorites.map(\.backupPlace), trips: library.trips,
                                                   preferences: session.backupPreferences, areas: session.namedAreas).selecting(exportSelection)
                        document = LibraryBackupDocument(data: try backup.encoded())
                        exporting = true
                    } catch { message = error.localizedDescription }
            }
        } message: {
            Text("This readable file can include saved locations, routes and area boundaries. Pairing files and helper keys are excluded. Only share it with someone you choose.")
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Shift-Library.json") { result in
            switch result {
            case .success: message = "Backup exported."
            case .failure(let error): message = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= LibraryBackup.maximumBytes else { throw BackupError.tooLarge }
                preview = try LibraryBackup.decode(Data(contentsOf: url))
                importSelection = (preview?.included ?? []).subtracting([.settings])
                message = nil
            } catch { preview = nil; message = error.localizedDescription }
        }
        .loggedConfirmationDialog("Import this backup?", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Import") { applyImport() }
        } message: { Text(importSelection.contains(.settings) ? "Adds missing saved items and replaces the included preferences." : "Adds missing saved items. Your preferences stay as they are.") }
    }

    private func categoryChoices(available: Set<BackupCategory>, selection: Binding<Set<BackupCategory>>) -> some View {
        ForEach(BackupCategory.allCases.filter { available.contains($0) }) { category in
            Toggle(category.title, isOn: Binding(
                get: { selection.wrappedValue.contains(category) },
                set: { enabled in
                    if enabled { selection.wrappedValue.insert(category) }
                    else { selection.wrappedValue.remove(category) }
                }
            ))
        }
    }

    private func applyImport() {
        guard !session.hasSession, !session.isBusy, let preview else {
            message = "End your location session before importing."
            return
        }
        do {
            guard !importSelection.isEmpty else { return }
            let selected = preview.selecting(importSelection.intersection(preview.included))
            let places = try LibraryMerge.places(local: session.favorites.map(\.backupPlace), incoming: selected.places)
            let areas = try LibraryMerge.areas(local: session.namedAreas, incoming: selected.areas ?? [])
            // Validate every category and capacity before the first persistent write.
            _ = try LibraryMerge.trips(local: library.trips, incoming: selected.trips)
            if importSelection.contains(.trips) {
                guard try library.merge(selected.trips) else { message = library.error; return }
            }
            session.importLibraryPlaces(places, settings: selected.preferences)
            if importSelection.contains(.places) { _ = session.replaceNamedAreas(areas) }
            if let settings = selected.preferences { planner.preferWalkingPaths = settings.preferWalkingPaths }
            self.preview = nil
            message = "Backup imported. Your saved library is ready."
        } catch { message = error.localizedDescription }
    }
}

private struct LibraryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

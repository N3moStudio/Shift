import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var isRoot = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var preferences: SessionPreferences
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("This iPhone") {
                        NavigationLink { ConnectionSettingsView() } label: { SettingsConnectionSummary() }
                        setting(.remoteFindMy)
                    }.shiftSettingsRows()
                    Section("Experience") {
                        setting(.appearance, value: appearanceName)
                        setting(.activity, value: preferences.liveActivities ? "On" : "Off")
                        setting(.widgets)
                        setting(.notifications)
                    }.shiftSettingsRows()
                    Section("Movement") {
                        setting(.speeds)
                        setting(.shortcuts)
                        setting(.recovery)
                    }.shiftSettingsRows()
                    Section("Your data") {
                        setting(.privacy)
                        setting(.backup)
                    }.shiftSettingsRows()
                    Section("Support") {
                        setting(.report)
                        setting(.diagnostics)
                        setting(.experimental)
                        setting(.about)
                    }.shiftSettingsRows()
                    Section { ShiftSignature().frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .listRowBackground(Color.clear)
                } else {
                    let matches = SettingsDestination.results(for: search)
                    if matches.isEmpty { ContentUnavailableView.search(text: search).listRowBackground(Color.clear) }
                    else { Section("Results") { ForEach(matches) { setting($0) } }.shiftSettingsRows() }
                }
            }
            .shiftSettingsScreen().loggedNavigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search, prompt: "Find a setting")
            .toolbar {
                if !isRoot { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }

    private func setting(_ item: SettingsDestination, value: String? = nil) -> some View {
        NavigationLink { destination(for: item) } label: {
            HStack(spacing: 12) {
                ShiftSettingsIcon(symbol: item.symbol)
                Text(item.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let value { Text(value).font(.subheadline).foregroundStyle(.secondary) }
            }.frame(minHeight: 44)
        }
    }

    @ViewBuilder private func destination(for item: SettingsDestination) -> some View {
        switch item {
        case .connection: ConnectionSettingsView()
        case .appearance: AppearanceSettingsView()
        case .activity, .notifications:
            List { SessionSettingsSections(category: item == .activity ? .activity : .warnings) }
                .shiftSettingsScreen().loggedNavigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        case .privacy:
            List { PrivacySettingsSection() }.shiftSettingsScreen().loggedNavigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        case .speeds: UsualSpeedsSettingsView()
        case .shortcuts: PanelShortcutsView()
        case .widgets: HomeWidgetsSettingsView()
        case .recovery: TripRecoveryView()
        case .experimental: ExperimentalFeaturesView()
        case .remoteFindMy: FindMyChecksView()
        case .report: ProblemReportView()
        case .diagnostics:
            List { DeveloperLogExportSection() }.shiftSettingsScreen()
                .loggedNavigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
        case .about: LocusAboutSettingsView()
        case .backup: LibraryBackupView()
        }
    }

    private var appearanceName: String {
        preferences.visualStyle.title
    }
}

private struct SettingsConnectionSummary: View {
    @EnvironmentObject private var session: SpoofSession
    var body: some View {
        ForegroundTimeline { _ in
            HStack(spacing: 12) {
                ShiftSettingsIcon(symbol: "antenna.radiowaves.left.and.right")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection").font(.body).foregroundStyle(.primary)
                    Text(session.effectivePhase.title).font(.subheadline).foregroundStyle(session.effectivePhase.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}

/// Details stay available without filling the screen before someone needs them.
struct SettingsHelp: View {
    var title = "How it works"
    let lines: [String]
    var body: some View {
        DisclosureGroup {
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index]).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 3)
            }
        } label: {
            Label(title, systemImage: "questionmark.circle")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.vertical, 3)
        }
    }
}

struct ConnectionSettingsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var showPairOnDevice = false
    @State private var confirmRemovePairing = false
    @State private var showSetupChecklist = false
    @State private var tunnelIP = TunnelConfig.targetIP
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
    var body: some View {
        List {
            SessionSettingsSections(category: .connection)
            Section {
                Button { showSetupChecklist = true } label: { Label("Review setup checklist", systemImage: "checklist").frame(minHeight: 44) }
                    .disabled(session.hasSession || session.isBusy)
                if session.hasSession { Text("Stop spoofing before running a setup check.").font(.footnote).foregroundStyle(.secondary) }
            }.shiftSettingsRows()
            Section("iPhone pairing") {
                Label(pairing.hasPairingFile ? "Pairing file ready" : "Pairing needed",
                      systemImage: pairing.hasPairingFile ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(pairing.hasPairingFile ? LocusTheme.statusGood : LocusTheme.statusWarn)
                if supportsOnDevicePairing {
                    Button("Pair on this iPhone") { showPairOnDevice = true }.frame(minHeight: 44)
                        .disabled(session.hasSession || session.isBusy)
                }
                DisclosureGroup("Import or manage pairing") {
                    Button("Import pairing file") { showImporter = true }.frame(minHeight: 44)
                    Button("Paste pairing file") {
                        do { try pairing.importPairingFromClipboard() }
                        catch { session.lastError = error.localizedDescription }
                    }.frame(minHeight: 44)
                    if pairing.hasPairingFile {
                        Button("Remove pairing file", role: .destructive) { confirmRemovePairing = true }
                            .frame(minHeight: 44).disabled(session.hasSession || session.isBusy)
                    }
                    Text("Use an RPPairing file from idevice_pair. A SideStore pairing file is different.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(session.hasSession || session.isBusy)
                if session.hasSession { Text("Stop spoofing before changing this iPhone’s pairing.").font(.footnote).foregroundStyle(.secondary) }
                SettingsHelp(title: "Pairing help", lines: [
                    supportsOnDevicePairing
                        ? "Tap Pair on this iPhone, then follow the code shown there. No computer is needed."
                        : "Create an RPPairing file with idevice_pair on a computer, then import it here.",
                    "Using LiveContainer? Enable Fix File Picker for Shift. You can also paste the file contents or share the file into LiveContainer → Shift."
                ])
            }.shiftSettingsRows()
            Section {
                Button(localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN") {
                    if localDevVPNInstalled { LocalDevVPN.openInstalled() }
                    else { LocalDevVPN.openAppStore() }
                }.frame(minHeight: 44)
                DisclosureGroup("Advanced connection settings") {
                    TextField("Device tunnel IP", text: $tunnelIP)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { TunnelConfig.setTargetIP(tunnelIP) }
                    Button("Save tunnel IP") { TunnelConfig.setTargetIP(tunnelIP) }
                    Text("Default: 10.7.0.1. Only change this if your VPN setup needs it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: { Text("Start on Wi-Fi with LocalDevVPN on. An existing connection may keep working on cellular.") }.shiftSettingsRows()
        }
        .shiftSettingsScreen().loggedNavigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(onPick: { url in
                showImporter = false
                do { try pairing.importPairing(from: url) }
                catch { session.lastError = error.localizedDescription }
            }, onCancel: { showImporter = false }).ignoresSafeArea()
        }
        .loggedConfirmationDialog("Remove this iPhone’s pairing?", isPresented: $confirmRemovePairing, titleVisibility: .visible) {
            Button("Remove pairing", role: .destructive) {
                guard !session.hasSession, !session.isBusy else { return }
                do { try pairing.removePairing() } catch { session.lastError = error.localizedDescription }
            }
        } message: { Text("You’ll need to pair this iPhone again before sending another location. Saved places and routes stay here.") }
        .sheet(isPresented: $showSetupChecklist) {
            SetupFlowView(initialStep: SetupGate.initialStep(hasPairingFile: pairing.hasPairingFile), onFinished: {
                SetupGate.markComplete(); showSetupChecklist = false
            }, onSkip: { showSetupChecklist = false })
        }
        .sheet(isPresented: $showPairOnDevice) { PairOnDeviceView().environmentObject(pairing) }
        .onAppear { localDevVPNInstalled = LocalDevVPN.isInstalled }
        .onChange(of: scenePhase) { _, phase in if phase == .active { localDevVPNInstalled = LocalDevVPN.isInstalled } }
    }
}

private struct LocusAboutSettingsView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 48.0
    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    ShiftMark().fill(LocusTheme.accent.gradient).frame(width: 72, height: 72).accessibilityHidden(true)
                    Text("Shift").font(.system(size: titleSize, weight: .bold, design: .rounded)).tracking(-2)
                    ShiftSignature()
                }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
            }.shiftSettingsRows()
            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Engine", value: "idevice DVT location simulation")
            }.shiftSettingsRows()
            Section("Built on open source") {
                Text("Shift is an independent fork of Locus, redesigned by N3mo Studio. Thanks to the Locus contributors and Jackson Coxson’s idevice project.")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink { ShiftAcknowledgmentsView() } label: { Label("Licenses & acknowledgments", systemImage: "text.document") }
                Link("Original Locus project", destination: URL(string: "https://github.com/ChrisMack32/Locus")!)
                Link("idevice project", destination: URL(string: "https://github.com/jkcoxson/idevice")!)
            }.shiftSettingsRows()
        }.shiftSettingsScreen().loggedNavigationTitle("About Shift").navigationBarTitleDisplayMode(.inline)
    }
}

struct PlacesView: View {
    var isRoot = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var category = LibraryCategory.places
    private enum LibraryCategory: String, CaseIterable { case places = "Places", routes = "Routes", areas = "Areas" }
    var onTrip: (SavedTrip) -> Void = { _ in }
    var onPlace: (SavedPlace) -> Void = { _ in }
    var onFindPlace: (() -> Void)? = nil
    var onCreateRoute: (() -> Void)? = nil
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var library: TripLibrary
    @State private var search = ""
    @State private var selectedFolder: String?
    @State private var folderPlace: SavedPlace?
    @State private var placeToRename: SavedPlace?
    @State private var areaEditor: NamedAreaDraft?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if typeSize.isAccessibilitySize { categoryPicker.pickerStyle(.menu) }
                    else { categoryPicker.pickerStyle(.segmented) }
                }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                if category == .areas {
                    NamedAreasSection(search: search) { area in
                        areaEditor = NamedAreaDraft(area: area, center: session.pin ?? session.simulated ?? session.realCoordinate)
                    }
                }
                if category != .areas && !folders.isEmpty {
                    Section {
                        Picker("Folder", selection: $selectedFolder) {
                            Text("All saved items").tag(String?.none)
                            ForEach(folders, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    }
                }
                if category == .routes { SavedTripsSection(onChoose: onTrip, search: search, folder: selectedFolder, folders: folders, onCreate: onCreateRoute) }
                if category == .places {
                Section("Favorites") {
                    if session.favorites.isEmpty {
                        Text("Star a pin from the map to save it.")
                            .foregroundStyle(.secondary)
                        if let onFindPlace {
                            Button("Find a place", systemImage: "magnifyingglass", action: onFindPlace)
                                .frame(minHeight: 44)
                        }
                    }
                    ForEach(session.favorites.filter { matches($0) && (selectedFolder == nil || $0.folder == selectedFolder) }) { place in
                        HStack {
                            placeButton(place)
                            Button { placeToRename = place } label: {
                                Image(systemName: "pencil").frame(width: 44, height: 44).contentShape(Rectangle())
                            }.buttonStyle(.borderless).accessibilityLabel("Edit \(place.displayName)")
                        }
                            .contextMenu { Button("Move to folder…") { folderPlace = place } }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeFavorite(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    placeToRename = place
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                }

                if selectedFolder == nil { Section("Recents") {
                    if session.recents.isEmpty {
                        Text(session.preferences.saveRecentLocations ? "Locations you choose appear here." : "Recent locations are turned off in Settings.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.recents.filter(matches)) { place in
                        placeButton(place)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeRecent(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
            }
                }
                Section {
                    NavigationLink { RecentlyDeletedView() } label: { Label("Recently Deleted", systemImage: "trash") }
                }
            }
            .searchable(text: $search, prompt: category == .routes ? "Search routes" : category == .areas ? "Search areas" : "Search places")
            .sheet(item: $folderPlace) { place in
                LibraryFolderSheet(current: place.folder, folders: folders) { session.moveFavorite(place, folder: $0) }
            }
            .shiftScreen().loggedNavigationTitle("Library")
            .fullScreenCover(item: $areaEditor) { draft in
                NamedAreaEditor(draft: draft) { area in
                    session.replaceNamedAreas(session.namedAreas.filter { $0.id != area.id } + [area])
                }
            }
            .toolbar {
                if !isRoot { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            }
            .sheet(item: $placeToRename) { place in
                SavedPlaceEditorSheet(place: place) { name, symbol, tint in
                    guard session.renameFavorite(place, to: name, icon: symbol, tint: tint) else {
                        return "This place is no longer saved. Close this editor and try again."
                    }
                    if name != place.name { library.renameLinkedPlace(place, to: name) }
                    return nil
                }
            }
        }
    }

    private var categoryPicker: some View {
        Picker("Library category", selection: $category) {
            ForEach(LibraryCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.frame(minHeight: 44)
    }
    private var folders: [String] {
        Array(Set(session.favorites.compactMap(\.folder) + library.trips.compactMap(\.folder))).sorted()
    }
    private func matches(_ place: SavedPlace) -> Bool {
        search.isEmpty || place.name.localizedCaseInsensitiveContains(search) || (place.folder?.localizedCaseInsensitiveContains(search) ?? false)
    }
    private func placeButton(_ place: SavedPlace) -> some View {
        Button {
            onPlace(place)
            if !isRoot { dismiss() }
        } label: {
            HStack(spacing: 14) {
                SavedPlaceBadge(symbol: place.symbol, tint: place.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(place.displayName).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                        .font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.borderless)
    }
}

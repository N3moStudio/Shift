# Shift app map

Maintained alongside the [Shift Change Ledger](CHANGE-LEDGER.md). Source paths
are relative to the repository. Current snapshot: 2.5.3 (51), 23 October 2026.
This continues the original source/branding catalog without treating historical
Locus identifiers as safe search-and-replace targets.

| Area | Main owners | Responsibilities |
| --- | --- | --- |
| App entry / privacy | `Locus/App/LocusApp.swift`, `Locus/Support/AppPrivacyController.swift`, `Shared/PrivacyRules.swift` | Setup, unlock, file/deep-link entry, protected content |
| Tabs / session tray | `Locus/Features/Map/RootView.swift` | Map/Library/Settings navigation, compact route controls, selected-tab restoration |
| Map / route planning | `Locus/Features/Map/MapHomeView.swift`, `Locus/Features/Routes/RoutePlannerSheet.swift`, `Locus/Engine/RoutePlanner.swift`, `RouteBuilder.swift` | Place selection, route alternatives, numbered timeline, editable plans |
| Stop durations | `Locus/Features/Routes/StopDurationControl.swift`, `RoutePlacesEditor.swift`, `TripViews.swift`; `Shared/SpeedUnit.swift`, `TripFeatures.swift`, `RouteLifecycle.swift` | One h/m/s editor across screens; shared bounds, countdown and live insertion |
| Rehearsal / editing | `Locus/Features/Routes/RouteEditorViews.swift`, `PathEditorSheet.swift`; `Shared/RouteEditing.swift` | Preview-only playback, seeking, stop restoration, path/section edits |
| Actual simulation | `Locus/Engine/SpoofSession.swift`, `Locus/Features/Routes/TravelControls.swift`, `Locus/Features/Joystick/JoystickPad.swift` | Commands, movement, pause/resume, confirmation evidence and stop progress |
| Units / library | `Shared/SpeedUnit.swift`, `Locus/Features/Settings/UsualSpeedsSettingsView.swift`, `SettingsView.swift`, `Shared/LibraryBackup.swift` | MPH/KPH at display boundary; saved speeds remain MPH; places/trips/backups |
| Interface / icons | `Shared/ShiftAppearance.swift`, `Locus/Support/ShiftAppearanceController.swift`, `Locus/Features/Settings/AppearanceSettingsView.swift` | Style, palette, icon preferences, native appearance transition |
| iPhone verification | `Locus/Support/LocationVerificationController.swift`, `Shared/LocationVerification.swift` | Fresh iOS location report compared to timestamped sent points; not proof of another app |
| External reports | `Locus/Support/CompanionClient.swift`, `RemoteFindMyController.swift`, `Companion/`, `CloudFindMy/` | Windows Apple/Life360 adapters and Render Apple/Life360 adapters; independent auth/error/freshness states |
| Live Activities / Island | `Locus/Engine/SessionActivityController.swift`, `Shared/SessionPresentation.swift`, `Shared/RemoteFindMy.swift`, `Shared/CloudServiceChecks.swift`, `LocusActivity/LocusLiveActivity.swift` | One activity with separate Find My and Life360 evidence, visibility preferences, stale handling and app links |
| Packaging / validation | `project.yml`, `Locus.xcodeproj/project.pbxproj`, `.github/workflows/build-ipa.yml`, `scripts/`, `Tests/` | Versions, identities, sources, model/helper tests, app/extension build, IPA validation |

## Branding boundaries

- Visible names and descriptions: SwiftUI copy, notifications, Info.plist display
  strings, help/setup, README/release text and helper pages. Review all together
  for any future selected name.
- Visual assets: `Brand/`, icon packages/catalogs, previews, screenshots, and the
  shared activity/widget mark. Update resource references and packaging checks.
- Compatibility contracts: bundle IDs/app groups, URL schemes, Keychain services,
  defaults keys, widget kinds, backup formats and helper protocols. These require
  a migration decision, not a blind replacement of Shift/Locus text.
- Attribution: retain upstream names in licensing, notices and historical facts.

No new brand has been selected. The 2.5.0 identity separation is already a storage
migration from 2.4.x; see [migration instructions](TESTING-2.5.md).

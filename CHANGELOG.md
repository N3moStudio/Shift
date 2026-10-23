# Changelog

## 2.5.0 (48) — development

- Enter route-stop waits in seconds (0–3,600), including stops under a minute.
- Choose mph or km/h throughout planning, movement controls, saved trips and history. Conversion uses exact factors; stored trip speeds keep full precision and remain backward compatible.
- Give Shift an independent app/extension bundle ID and app group, and stop claiming Locus's URL scheme. See [migration notes](docs/TESTING-2.5.md) before installing.
- Open session details from notification taps, suppress duplicate foreground connection banners, and offer connection details from session alerts.
- Validate pairing candidates with the engine decoder before replacing the installed file.
- Default detailed logging to off on fresh installs and scale the About title with Dynamic Type.
- Add Find a place and Create a route actions to empty Library categories.


The recorded evolution from the original Locus snapshot to **Shift 2.4.4 (47)**.
This history was reconstructed from saved source archives and update notes,
including changes made between Git pushes. These are this fork’s milestones,
not upstream Locus release numbers. Some builds were internal or diagnostic;
not every version was publicly released. Dates are omitted where no reliable
release record exists. Related edits made under the same version are grouped.

Historical entries describe what changed **then**. They do not mean removed
features—such as tutorials, app-specific Battery Saver or the notification
preview—are present now. Current features are in the [README](README.md).

## What changed from the starting app

| Area | Shift’s cumulative additions and revisions |
| --- | --- |
| Identity & interface | Shift / N3mo Studio branding; Map, Library and Settings; Glacier, Afterhours and Porcelain; nine independent icons |
| Movement | Preview-first teleport, refined joystick, directions and route alternatives, drawing/editing, stops, waits, per-section speeds and route jumps |
| Library | Named places/areas, folders/search, saved trips, duplication, three-version edit history, Recently Deleted and export/import |
| Status | Timestamped command evidence, unverified/stale states, Live Activities, Dynamic Island, widgets and recovery |
| Optional checks | Self-hosted cloud/Windows helpers, Find My Devices comparisons, readiness tests and configurable Shift connection checks |
| Privacy & efficiency | Device-authentication lock, display privacy, reviewed local exports, bounded logs, quieter timers and comparable reliability runs |

## 2.4.4 · build 47 — Public build follow-up · 15 October 2026

- Fixed the final IPA appearance check to accept Xcode asset-catalog icon declarations while still checking the expected icon names. Portable system-size PNG validation remains in place.
- Corrected the default app icon's dark/tinted filename capitalization and added exact-name source checks so Windows cannot hide a mismatch from the build runner.
- Added 12 packaging regression tests to GitHub Actions. The local regression suite passed; earlier build logs recorded 279 Swift model tests and 69 helper tests passing.
- Confirmed a successful GitHub Actions build after the validation fix. The maintainer reported that the IPA installs and works on their iPhone; this is a device smoke check, not verification of every feature or supported configuration.
- Configured direct IPA artifact downloads and automatic filenames from the built app version, currently `Shift 2.4.4.ipa`, without an outer artifact ZIP.

## Public repository preparation · 14 October 2026

- Refreshed the README and brand presentation; consolidated private hand-off notes into this history and current guides.
- Added current release copy, upload instructions, contribution/issue templates and explicit MIT attribution for Shift alongside upstream notices.
- Retained the verified 2.4.4 runtime source. Removed personal compiler paths from the public IPA copy, preserving executable/data sections and entitlements, and recomputed its ad-hoc signature hashes. Packaging is not a new feature build or on-device validation.

## 2.4.4 · build 47 — Native notifications

- Removed the test-banner settings section, preview scheduler and preview messages introduced in 2.4.3.
- Retained native alternate-icon selection and existing pairing, reminder and connection notifications. No extra timer, polling or background activity was added.
- Preserved the 2.4.1 launch fix, native tab navigation, all icon choices, helper protocols and app identities. An iOS-cached notification icon is not claimed to be fixed.

## 2.4.3 · build 46 — Temporary notification preview — superseded

- Added a one-shot Send Test Banner action to App Icon settings, with permission/error handling and a five-second trigger.
- Used an ordinary system notification to inspect the current icon; it did not override the banner icon or clear iOS caches.
- This feature was removed in 2.4.4 and is not part of the current interface.

## 2.4.2 · build 45 — Native glass navigation and complete icon sizes

- Moved Map, Library and Settings to the current native Tab API with filled symbols and the selected style’s accent. Kept the bar expanded during map navigation and intentionally hidden in drawing editors.
- Renamed the map-panel switch to Liquid Glass Map Controls; system navigation remains governed by iOS appearance and accessibility.
- Corrected portable-build linked-SDK metadata to the actual iOS 27.1 SDK instead of the iOS 18 deployment target.
- Bundled notification/settings/search/Home Screen sizes for all nine portable icon choices and added a package validator for icon resources and linked SDK metadata.
- Kept regular notification badges system-controlled; the Live Activity’s own mark follows the selected icon design.

## 2.4.1 · build 44 — First-launch crash repair

- Fixed an appearance-anchor exception caused by reading a custom trait override before one existed. The anchor now reads the resolved trait collection before updating overrides.
- Removed the diagnostic launch screen/handlers. Preserved appearance choices, app data and bundle IDs.

## 2.4.0 · diagnostic builds 42–43 — Launch investigation

- Temporary launch-check builds recorded startup stages and captured the appearance-trait exception after the main screen opened.
- These were diagnostic iterations of 2.4.0, not separate feature releases. Their launch gate is absent from the normal 2.4.1+ builds.

## 2.4.0 · build 41 — Three styles, nine icons

- Added Glacier (ice blue/silver), Afterhours (ink/violet) and Porcelain (chalk/graphite), each with light/dark palettes, setup treatment, control shapes, settings surfaces and widget/activity colors.
- Added Default, Dark and Tinted icon choices for each family, independent of interface style. Saved selection only after iOS confirmed the icon change.
- Included native appearance asset catalogs and portable manual icon choices. Appearance changes add no network, location or polling work.
- This initial appearance build had a first-launch crash, repaired in 2.4.1; do not use it in preference to the current release.

## 2.3.2 · build 40 — Stable area drafts and simpler helpers

- Moved named-area presentation out of reusable list sections, retained one draft identity/camera/corner list, and separated it from recurring session-status updates. Added discard confirmation.
- Added a 3–15 second Connection checks setting (default 10) for held-session evidence and Live Activity freshness. Route/joystick movement and Apple helper polling remain separate.
- Unified Find My checks around Cloud helper and Windows helper. Added direct Render URL/key connection, compatible setup-file import and an authenticated readiness test that does not start monitoring.
- Added Windows local-address detection and protected persistent pairing identity. Restarts on the same address retain pairing; changed addresses or renewed credentials require re-import.
- Added Windows session evidence to Live Activities, one-active-helper selection and specific connection errors.
- Changed generated pairing/export/helper branding to Shift while retaining legacy imports, storage IDs and deep links.
- Prepared reusable public source without a built-in personal Render URL, helper key, account or deployed service.

## 2.3.1 · build 39 — Touch capture, map-relative joystick and quieter idle work

- Moved route/area input onto a fixed surface above MapKit so taps and freehand input do not compete with native map recognizers. Coordinated second-finger cancellation, pan, pinch and parent scrolling.
- Made joystick movement follow the visible map heading on each tick, using the fixed pad rather than the moving thumb as its coordinate space.
- Reduced initial setup to a Wi-Fi / LocalDevVPN / pairing checklist with one readiness-driven primary action and expandable pairing options.
- In a follow-up under the same version, limited idle foreground location demand to visible map use and made the device-origin picker one bounded, cancellable request.
- Added eight saved battery/reliability results and two-run comparisons with foreground/away time, Low Power Mode, charging, interruption and configuration context. Observes battery notifications only during a test; does not claim app-only energy measurement.

## 2.3.0 · build 38 — Map, library and setup redesign

- Introduced the Map / Library / Settings navigation structure, refreshed setup/settings/editor surfaces, and a new default/dark/tinted icon direction.
- Reworked map drawing navigation to address vertical drift and parent-sheet scrolling during two-finger pan/zoom, including projection and anchoring checks.
- Expanded accessible point editing and directional movement controls, with reduced-motion/transparency support.
- Restyled helper pages and setup directions while preserving existing URLs, authentication and setup-file formats. Follow-up input corrections shipped in 2.3.1.

## 2.2.6 · build 37 — Paused routes and buffered logs

- Changed paused-route work from frequent wake-ups to control/connection signals. Resume, seek and cancellation wake it; paused time is not added to the next movement step.
- Grouped routine command and activity log writes into 32 KiB batches or five-second flushes. Failures, user actions, exports and lifecycle changes flush promptly.
- Kept held-location refresh and clear-command ordering. A sudden exit can lose the last buffered routine log entries; battery savings were not measured.

## 2.2.5 · build 36 — Less unnecessary background work

- Shared the session monitor with remote Find My, reused its network session, and added bounded failure backoff with manual retry.
- Let the held-location monitor sleep until relevant deadlines; stopped movement timers for an untouched joystick.
- Paused status timers and automatic camera following where their views are inactive or hidden. Skipped unchanged Live Activity evidence and helper-only recovery writes.
- Preserved location-command timing, evidence expiry and helper credentials. No fixed battery-saving percentage was claimed.

## 2.2.4 · build 35 — Find My freshness and activity evidence

- Displayed remote Find My evidence separately from successful spoofing commands in Live Activities and Dynamic Island; distinguished Apple report age from helper reply age.
- Corrected a helper cache path that returned before a due refresh. Concurrent checks share one refresh and wait briefly for a fresh snapshot without duplicate Apple requests.
- Preserved Apple timestamps, freshness limits and rate limiting. Old reports remain old; the change cannot force Apple to update.

## 2.2.3 · build 34 — Render browser setup

- Added private browser-based helper setup: unlock, Apple sign-in/verification, choose a device, download pairing and reconnect from the phone.
- Added HTTPS Render pairing alongside the existing pinned-certificate and Windows formats, plus a public health endpoint without private data.
- Stable helper keys preserve phone pairing across server restarts; the Apple login must be renewed. Health pings do not extend an inactive monitoring session.

## 2.2.2 · build 33 — Native recognizer attachment repair

- Corrected two map gesture attachment sites to use the supported native recognizer modifier instead of SwiftUI simultaneousGesture.
- Preserved callbacks, coordinate conversions, simultaneous map navigation and the smaller view components from 2.2.1.

## 2.2.1 · build 32 — Map expression build repair

- Split the oversized map expression into smaller content, gesture and overlay functions after a Swift type-check timeout.
- Kept pin adjustment, magnifier, saved-place appearance, search and duplication behavior. A further native modifier correction followed in 2.2.2.

## 2.2.0 · build 31 — Precise pins and personal places

- Added hold-and-drag pin adjustment with a magnifier; release remains a preview until Teleport is tapped.
- Added saved-place names, ten icons and six colors, preserving them through backups and Recently Deleted.
- Added local Settings search with everyday aliases and visible trip duplication actions. Copies retain route settings and do not start movement.

## 2.1.5 · build 30 — Map input and route-planner cleanup

- Captured map touches at first contact in map coordinates and removed pin insertion animation; restricted route-hold recognition to existing routes.
- Grouped route endpoints, compacted mode/speed controls, and reorganized optional stops, arrival and movement settings.
- Smoothed drawing presentation and batched coalesced touch samples with a stable overlay and cached distance, reducing repeated work.

## 2.1.4 · build 29 — Glass settings

- Added grouped glass settings surfaces, featured Appearance/Live Activities choices, clearer icons and full-width rows.
- Added accessible large-text layouts and solid contrast/transparency fallbacks. Kept all settings destinations and existing engine behavior.

## 2.1.3 · build 28 — Settings build fixes

- Corrected the Experimental Features section declaration and moved battery conversion into the session-test model after Battery Saver removal.
- Added battery-reading validation tests; retained the simplified settings from 2.1.2.

## 2.1.2 · build 27 — Calmer settings

- Shortened rows and repeated explanations; moved experimental service checks and reliability tools into their own area.
- Reduced helper setup to small steps with direct import for existing setup files. Kept export/privacy warnings and current errors visible.

## 2.1.1 · build 26 — Removed the app-specific Battery Saver

- Removed the separate Shift Battery Saver, exception controls, confirmation prompts and activity battery cutoff.
- Returned glass and Live Activities to their own switches. iPhone Low Power Mode and accessibility remain system controls.
- Kept old backups compatible while ignoring retired Saver fields and removing the retired shortcut.

## 2.1.0 · build 25 — Remote Find My prototype

- Added opt-in cloud helper checks during active sessions, timestamp-based report comparisons and expiring match evidence.
- Added helper/sign-in/mismatch warnings and a no-recent-confirmation reminder, without claiming force-close detection.
- Introduced bounded server-memory monitoring leases and scoped device helper-key storage. No Find My People integration or independent push service.

## 2.0.1 · build 24 — Simpler setup and helper onboarding

- Refreshed first-use cards, shortened connection instructions and tucked optional import controls away.
- Moved timeline/problem markers into Export or import; added dedicated Windows helper setup and shareable helper downloads.
- Clarified recovery requirements, compacted joystick/naming controls, and added Battery Saver exceptions that were later removed in 2.1.1.

## 2.0.0 · build 23 — Locus becomes Shift

- Introduced Shift by N3mo Studio, the original ribbon mark, sea-glass/ink palette and a full-screen map with capsule search and a glass dock.
- Redesigned the planner, saved library, search, setup, settings, editors, widgets and Live Activities while keeping explicit preview/start controls.
- Added bundled source credits and license notices with packaging checks.
- Preserved the Locus app/group/storage identities, pairing and library formats for in-place upgrades. The original engine was not replaced.

## 1.12.0 · build 22 — Timeline, saved search and edit history

- Added a local session timeline and explicit problem markers tied to the developer log, without automatic uploads.
- Added saved place/trip name search alongside Apple results.
- Kept up to three distinct earlier saved-trip versions with preview, restore/undo, stale-edit protection and atomic persistence. Current-trip export excludes historical versions.

## 1.11.1 · build 21 — Alert logging build fix

- Added the missing alert-helper overload used by trip rename, preserving popup behavior and presentation logging.

## 1.11.0 · build 20 — Recovery and developer logs

- Clarified unfinished-session recovery and failed clear operations instead of reporting success without evidence.
- Improved continuous hold-to-drag route marker interaction and coordinate alignment.
- Added a local, exportable 48-hour developer log with bounded storage, explicit event markers, credential exclusions and honest gaps after suspension/termination.

## 1.10.0 · build 19 — Editing, widgets and optional computer checks

- Added explicit Map / Draw / Pan tools, a below-finger drawing cursor, and point/corner editing with insertion, movement, deletion and undo/redo.
- Added 30-day Recently Deleted for saved places, trips and areas, with safe persistence and restore behavior.
- Added Home Screen shortcuts/widgets, connection details and optional iPhone readback evidence.
- Added the Windows Find My Devices/Life360 helper prototype and compatible backup settings.
- Added an app-specific Battery Saver; it was subsequently removed in Shift 2.1.1.

## 1.9.1 · build 18 — Removed tutorials and simplified drawing

- Removed tutorials, quizzes and tutorial menus while retaining connection setup.
- Kept Export or import at the bottom of Settings; made the compact map panel default to clear glass without resizing the map.
- Simplified tap/freehand drawing and two-finger navigation, and changed new-install location-name privacy defaults. The explicit Pan tool returned in 1.10.0.

## 1.9.0 · build 17 — Named areas and better library organization

- Treated VPN-interface detection as a hint rather than a connection gate; setup checks the actual developer connection.
- Added named areas with polygon containment/overlap rules, persistent place names, rename controls and labels throughout routes and activities.
- Added route place/stop names and waits, selective export/import for places/areas, trips and settings, and compatibility with 1.8 backups.
- Refined panel collapse and app-switcher privacy explanations. An intermediate build correction was issued under the same version.

## 1.8.0 · build 16 — Recovery, reliability and library backups

- Added recoverable trip checkpoints and explicit Resume; reopening alone never starts travel.
- Added a session reliability test, arrival choices, configurable panel shortcuts, folders and saved-library search.
- Added duplicate-and-edit trips and previewed library backup import/merge, excluding pairing, app-lock and other private connection state.

## 1.7.0 · build 15 — Preview-first journeys and compact controls

- Separated Show route from Start route, isolated planner drafts from running sessions, and introduced per-mode usual-speed presets.
- Added future stops during playback, improved route-jump selection and changed Undo jump to ten seconds.
- Refined activity wording, compact controls and temporary place naming; added an activity battery cutoff that was later removed.
- Added optional tutorials and settings grouping. Tutorials were removed in 1.9.1.

## 1.6.0 · build 14 — Setup, practice and privacy tools

- Added guided Wi-Fi/tunnel/pairing/connection verification with cancellation and expiring setup evidence.
- Added per-section route modes, draggable stops/endpoint editing and route practice without location commands.
- Added optional device-authentication app lock, app-switcher protection and recent-location retention controls.
- Added explicit, previewed problem-report sharing with an allowlisted set of diagnostic fields.

## 1.5.3 · build 13 — Touch targets and readable places

- Removed irrelevant idle speed controls and expanded button hit areas.
- Changed smooth movement’s default to off, retaining later explicit choices and per-trip settings.
- Added temporary session/place labels governed by activity privacy choices and optional clear glass controls.
- Clarified the distinction between an airplane-mode/network change, an active developer connection and successfully clearing a simulated location.

## 1.5.2 · builds 11–12 — Precise map coordinates and route timing

- Changed search teleport selection to pin preview before an explicit location command.
- Unified touch/map coordinate spaces, refined freehand sampling and route-marker snapping, and used flat map geometry.
- Made route pacing account for command duration while bounding catch-up after long execution gaps.
- Added honest device-origin selection without treating a simulated fix as fresh physical GPS, plus separate activity-surface privacy/progress preferences.
- Included a compiler correction in build 12 under the same version.

## 1.5.1 · build 10 — Stable viewport and cancellable actions

- Kept the map viewport fixed under an overlay tray and removed competing whole-map gestures.
- Improved route-marker hit targets, explicit Teleport/Plan search choices and cancellation of stale search results.
- Preserved paused route state during retry, queued explicit teleport behind in-flight writes and reduced redundant state/geometry updates.

## 1.5.0 · build 9 — Saved trips and stops

- Added saved trips with atomic persistence, rename/delete and full route/settings restoration into a preview.
- Added stops and waiting times, route pauses, reorder controls and continued wait-state handling.
- Added optional gradual acceleration/braking/turn slowing and Undo jump with stop-history restoration.
- Changed status wording to distinguish the last accepted command from independent proof of another app’s location.

## 1.4.0 — Flexible movement and route drawing

- Added explicit walking-path fallback/preference for cycling, live mode/speed changes and confirmed reroute choices.
- Added per-mode saved speed controls, a collapsible map panel and route-jump preview/confirmation.
- Added tap-point/freehand/pan drawing with bounded undo/redo and explicit review before movement.

## 1.3.1 — Simpler route and joystick controls

- Restricted joystick opening to an established session and separated Pause, Continue, End route and Stop spoofing.
- Added a fixed Start route action, isolated search/planner drafts from teleport pins, and prevented cancelled/late route writes from resuming travel.

## 1.3.0 — Directions and live journeys

- Added editable route endpoints, available route alternatives, source/distance/advisory information and separate simulation-time estimates.
- Added confirmed progress, pause/resume, map following/recenter/overview and journey details in Live Activities.

## 1.2.0 — Cycling and e-bike controls

- Added cycling/e-bike routing requests and persisted e-bike speeds for routes and joystick.
- Added route provenance and estimated travel time, with stale route-request rejection and explicit coverage/error handling.

## 1.1.0 — First custom session experience

- Introduced the custom map/session panel, appearance choices, accessible labeled controls and local Live Activity/WidgetKit extension.
- Added Lock Screen/Dynamic Island privacy, reminders and deduplicated warnings with timestamped command evidence and expiry.
- Serialized connection work, guarded cancellation/late completions, and made Stop wait for in-flight writes without inventing successful cleanup.
- Added honest relaunch/unverified states and Low Power Mode presentation adjustments. An early compiler correction was incorporated into the saved source.

## Starting point — upstream Locus

The first custom archive records
[`ChrisMack32/Locus@83c8fb324983728e8f44759cfd834dc637ee38b5`](https://github.com/ChrisMack32/Locus/tree/83c8fb324983728e8f44759cfd834dc637ee38b5)
as its base. Locus and the idevice engine provided the underlying application,
pairing and location-simulation foundation. Their copyright/license notices
remain intact. This changelog does not claim those foundations were created by
N3mo Studio or invent a release number for that starting snapshot.

The original binary dependency remains bundled; no new vendor-engine rewrite
is part of this history. See [credits and scope](NOTICE.md).

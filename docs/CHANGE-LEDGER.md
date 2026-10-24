# Shift Change Ledger

The release log and source map for this fork. Update this ledger and
[CHANGELOG.md](../CHANGELOG.md) for every version/build; record failed or repaired
build attempts under the same entry without presenting an earlier success as a
later build's result. Dates use America/Los_Angeles. Commit descriptions should
name the behavior changed and the affected area.

## Distribution policy

- Development work stays on `codex/shift-2.5.0` until explicitly promoted.
- Test releases are prereleases and must not replace the stable Latest release.
- A new release includes version/build, exact changes, tested commit, workflow,
  validation, remaining device checks, installation notes and IPA checksum.
- Repository check on 23 October 2026: only the maintainer's **v2.4.4** release
  existed. Builds 48 and 49 were Actions artifacts, not published releases.

## Build register

| Version / build | Date | Changes | Validation / distribution |
| --- | --- | --- | --- |
| 2.5.0 / 48 | 22 Oct 2026 | Seconds-based stops; mph/km/h with exact conversions; separate Shift app/extension IDs and app group; notification routing; pairing validation; logging opt-in; Library empty states and About accessibility | [Run 39913718958](https://github.com/N3moStudio/Shift/actions/runs/39913718958), commit `9525f0916ee7a99d3e85a2eb75c351049404db8b`: 373 tests passed (290 Swift, 14 packaging, 19 Windows, 50 cloud); app + extension + packaged IPA passed. Actions artifact only. |
| 2.5.1 / 49 | 23 Oct 2026 | Compact active-route controls; numbered planner; wait presets / Apply to all; preview scrubbing / stop jumps; deferred icon preferences and restored tab | [Run 39986538008](https://github.com/N3moStudio/Shift/actions/runs/39986538008), commit `275eb1791ed6d18df049e8f3852eff6370d41bd6`: 377 tests passed (294 Swift, 14 packaging, 19 Windows, 50 cloud); app + extension + packaged IPA passed. User confirmed installation; icon smoothness and full device matrix remain unverified. Actions artifact only. |
| 2.5.2 / 50 | 23 Oct 2026 | Hours/minutes/seconds up to 24 hours throughout route waits; long-duration display; validation and persistence coverage; maintained source/change map and verification guidance | [Run 40052908812](https://github.com/N3moStudio/Shift/actions/runs/40052908812), commit `b451c9d2362eed965a4f591ece96609d019b74da`: 384 tests passed (301 Swift, 14 packaging, 19 Windows, 50 cloud); Xcode 27.1 app + extension + packaged IPA passed in 3m 23s. Prerelease `v2.5.2-beta.1`; device acceptance pending. |
| 2.5.3 / 51 | 23 Oct 2026 | Cloud Life360 alongside Find My; one Live Activity with separate service statuses and visibility; clearer cloud recovery; free uptime setup | [Run 40066390461](https://github.com/N3moStudio/Shift/actions/runs/40066390461), commit `fe62fb4e11493fff14fdc663ba0f2bbb1e6da579`: 402 tests passed (307 Swift, 14 packaging/icon, 19 Windows, 62 cloud); Xcode 27.1 app + extension + packaged IPA passed in 2m 33s. Prerelease `v2.5.3-beta.1`; real provider sign-in and device acceptance pending. |

Build 48 IPA SHA256: `48db5d6715a90dc5f31551653f0f09020f3de6ae71948a0948e0f0a876827848`.
Build 49 IPA SHA256: `e9e6741540732baa2a6def85a9bb3497d8f8f3c48c32f4306e7722a5174be23e`.
Build 50 IPA SHA256: `28a918c6b78f244966a8761e61800d9ef2d1f767c3f74ab5755946880f8ac916`
(8,958,279 bytes). The release source includes documentation-only follow-ups
recording this result and build 49's earlier attempt; executable sources match
the tested commit above.

### Build 49 attempts

- 09:21 PDT: [run 39986065262](https://github.com/N3moStudio/Shift/actions/runs/39986065262),
  commit `eeec785f480badc5e81d4b3066bc733c9ff2a12c`, succeeded in 2m 44s.
  Initial interface build; IPA SHA256
  `fd400d8842c27ac668fba2b3fa36ed26e14e081ddb6f7b6184b278e020b11470`.
- 09:24 PDT: [run 39986538008](https://github.com/N3moStudio/Shift/actions/runs/39986538008),
  commit `275eb1791ed6d18df049e8f3852eff6370d41bd6`, succeeded in 2m 58s.
  Follow-up in `RouteEditorViews.swift` and `RoutePlannerSheet.swift`: name the
  orange preview dot accurately for accessibility, direct reordering help to the
  route timeline, and explain retained section settings on saved paths. This is
  the build 49 IPA delivered to the user. No additional version number was assigned.

### Build 51 attempts

- 22:22 PDT: [run 40066022555](https://github.com/N3moStudio/Shift/actions/runs/40066022555),
  commit `8611c80f80df895688f0365b003debbef003cf7f`, succeeded in 2m 39s.
  Initial cloud/dual-provider activity build: 402 tests passed (307 Swift,
  14 packaging/icon, 19 Windows-helper, 62 cloud-helper), then Xcode 27.1
  compiled the app and extension and packaged the IPA. Artifact: 9,008,015 bytes;
  SHA256 `2f478350807aeada584b34363d6eef6ba8296ab734ec53328e332c69f261d645`.
- 22:28 PDT: [run 40066390461](https://github.com/N3moStudio/Shift/actions/runs/40066390461),
  commit `fe62fb4e11493fff14fdc663ba0f2bbb1e6da579`, succeeded in 2m 33s.
  The same 402 tests passed; Xcode 27.1 built the app/extension and the final IPA
  passed packaging checks. Downloaded IPA: 9,012,586 bytes; SHA256
  `dcd0bfb046019014acca9140bcc6464068abcd639f5089faed308a915a53507b`.
  Both app and extension identify as version 2.5.3, build 51.
  Follow-up in `LocusActivity/LocusLiveActivity.swift`: one compact status/age
  row per service in the expanded Island, and the command timer appears only
  in its existing top corner. Full descriptions remain on the Lock Screen and
  in accessibility labels. This is the IPA delivered in prerelease
  `v2.5.3-beta.1`. The release source adds documentation-only result updates;
  executable and bundled helper sources remain identical to the tested commit.

## 2.5.2 change inventory

| Files | Exact responsibility / change |
| --- | --- |
| `Shared/SpeedUnit.swift` | One 0–86,400-second range, validation, component editing and h/m/s formatting. Aggregate totals do not inherit the per-stop cap. |
| `Shared/TripFeatures.swift`, `Shared/RouteLifecycle.swift` | Saved-route and live-insertion validation use the same duration rule. |
| `Locus/Engine/RoutePlanner.swift` | Draft edits, all-stop edits, added path stops and place edits retain waits through 24 hours. |
| `Locus/Features/Routes/StopDurationControl.swift` | Three labeled time wheels, accessibility menus, six presets, 24-hour boundary, pause explanation; existing cancelable sheet and Apply to all retained. |
| `Locus/Features/Routes/RoutePlannerSheet.swift`, `RouteEditorViews.swift`, `TripViews.swift` | Readable route-total, rehearsal and active-stop countdowns. |
| `Tests/SpeedUnitTests.swift`, `RouteLifecycleTests.swift`, `TripFeaturesTests.swift`, `LibraryBackupTests.swift`, `RouteEditingTests.swift` | Seven new regression tests: all selectable seconds; component edits; labels/totals; live insertion; countdown/recovery/save; backup bounds; preview pause/seek. Update two old one-hour assertions. |
| `project.yml`, `Locus.xcodeproj/project.pbxproj` | App and extension version 2.5.2, build 50. Identities unchanged. |
| `README.md`, `CHANGELOG.md`, `docs/TESTING-2.5.md` | Current feature description, dated history and concrete device checklist. |
| `docs/APP-MAP.md`, `docs/VERIFICATION.md`, this ledger | Maintained ownership map, existing verification capabilities and explicitly proposed improvements. |

No rebrand, new helper deployment, Life360 Island integration or monitoring
subscription is included in build 50. Existing preferences, saved seconds,
bundle IDs, helper credentials and migration behavior stay compatible with 2.5.x.
Older versions may reject backups containing stops longer than one hour.

See [App map](APP-MAP.md) for the broader catalog and [device checks](TESTING-2.5.md)
for what an automated build does not prove.

## 2.5.3 change inventory

| Files | Exact responsibility / change |
| --- | --- |
| `CloudFindMy/web_life360.py`, `render_server.py`, `requirements.txt` | Async memory-only Life360 observer adapter; protected browser setup, independent provider stores/polling; optional response/capability fields; legacy Apple clients remain valid |
| `CloudFindMy/test_life360.py`, `test_render.py` | Twelve new tests for consent/auth/CSRF, report time, selected profile, provider isolation, lease expiry, stop races, readiness and pinned-library API; extend existing status expectations |
| `Shared/RemoteFindMy.swift`, `CloudServiceChecks.swift` | Optional provider-validated Life360 response; local/cloud verdict agreement, independent freshness, source language and transport error mapping |
| `Locus/Support/RemoteFindMyController.swift`, `CompanionClient.swift` | Per-service cloud consent, old-helper handling, independent evidence and Life360 warnings; existing Windows reports also reach the activity |
| `LocusActivity/LocusLiveActivity.swift`, `Shared/SessionPresentation.swift`, `Locus/Engine/SessionActivityController.swift`, `SpoofSession.swift` | One activity containing both services, separate compact icons and ages; one compact row per service and one command timer in expanded Island; clear both when ending |
| `Locus/Support/SessionPreferences.swift`, `Locus/App/LocusApp.swift`, `Shared/LibraryBackup.swift` | Persist visibility, refresh immediately, optional backup fields without copying service consent or secrets |
| `Locus/Features/Settings/RemoteFindMyView.swift`, `FindMyChecksView.swift`, `ConnectionDetailsView.swift`, `SessionSettingsSections.swift`, `Shared/Personalization.swift` | Find My & Life360 entry, readiness/errors, checking versus visibility, uptime URL sharing and free setup |
| `Tests/CloudServiceChecksTests.swift` | Six tests for compatibility, isolated failures/freshness, local evidence, provider identity, bounded activity payload and errors |
| `scripts/package_helpers.py`, `Locus/Resources/Shift-FindMy-Cloud.zip` | Deterministic source-only cloud download includes Life360 adapter/tests |
| `project.yml`, `Locus.xcodeproj/project.pbxproj` | App/extension 2.5.3 build 51; shared service model in both targets |
| `README.md`, `CHANGELOG.md`, cloud setup/checklist, `docs/APP-MAP.md`, `TESTING-2.5.md`, `VERIFICATION.md`, this ledger | Current capabilities, helper upgrade, limits, ownership and acceptance checks |
| `docs/BATTERY-OPTIONS.md` | Twelve proposals for approval only; no battery optimization implementation |

External Apple/Life360 login and physical-iPhone Island/background behavior are
not claimed as verified by unit tests. No cloud account was provisioned or paid
plan selected. Deploy the updated helper separately and sign in to each provider.

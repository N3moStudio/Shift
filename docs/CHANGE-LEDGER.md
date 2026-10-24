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

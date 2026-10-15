# Validation

## Public GitHub build — 2.4.4, build 47 · 15 October 2026

- The original uploaded run compiled the app and extension successfully but failed the final IPA icon validator. It also warned about the capitalization of two default-icon image filenames.
- Those issues were corrected in commit `b7278e8`. The maintainer supplied a GitHub Actions screenshot showing the corrected run succeeded.
- The supplied logs recorded 279 Swift model tests and 69 Windows/cloud helper tests passing. The 12 new IPA/resource regression tests passed locally and were added to the workflow before the successful rerun.
- The maintainer subsequently confirmed that the IPA installs and works on their iPhone. This records basic on-device use; a detailed per-feature checklist and exact tested IPA checksum were not supplied.
- Commit `53bb018` subsequently configured direct downloads and version-derived filenames. The successful screenshot above predates that download change; it is not evidence of a separate completed run for that upload behavior.

The release notes no longer carry the checksum or SDK-specific packaging claims
from the earlier portable IPA. Record the exact tested IPA's hash and build run
when attaching it to a release. A renamed file keeps the same bytes and hash;
a rebuilt or re-signed IPA may not.

## Earlier portable package — historical evidence

The earlier 2.4.4 portable package passed 279 Foundation tests in Swift/Linux,
compiled the app and extension against iOS SDK 27.1, and passed archive,
entitlement, resource, notice and portable-icon checks. Its public copy redacted
local compiler paths and recomputed ad-hoc signature/resource hashes.

That package used explicit system-size icon PNGs. Native Xcode builds use asset
catalogs, including any/dark/tinted artwork. The two packages have different
build evidence and must not share an assumed checksum simply because both
identify as 2.4.4 (47).

## Device checks before relying on a release

1. Launch cleanly, update over an existing install, and confirm pairing/library retention with the same signing setup.
2. Test pairing, a connection check, teleport, Stop, and recovery after a failed clear. A failure must stay visible.
3. Draw/tap/edit a route and a named area; pan/pinch with two fingers, wait through status updates, then undo, cancel and save. Drafts and the map must remain stable.
4. Rotate the map and move the joystick in all directions; release/background it and confirm movement stops.
5. Start/pause/resume/end a route, exercise stops and jumps, and check the last point before Stop.
6. Switch all styles and icons, light/dark, large text, VoiceOver, Reduce Motion and Reduce Transparency. Confirm a fresh regular notification on the device; do not infer it from the Home Screen icon.
7. Check widgets and Live Activities with extension signing intact, including stale evidence, privacy settings and an unavailable helper.
8. Export/import a library, restore a deleted item and an earlier trip version. Do not use your only backup for testing.
9. Compare similar battery/reliability runs; account for charging, screen use, signal, Low Power Mode and interrupted execution.

Passing model tests and an IPA build do not establish native gesture behavior,
account sign-in success, notification appearance, or continuous background operation.

# Validation

## Included 2.4.4 IPA — build 47

- 279 Foundation tests passed in the local Swift/Linux run.
- The app and Live Activity/widget extension compiled for arm64 iOS with the installed iOS 27.1 SDK and an iOS 18 deployment target.
- Archive checks verified bundle identities, app-group entitlements, 9 icon choices / 126 portable system-size icon PNGs, 9 previews, helper archive hashes, and license notices.
- The diagnostic launch gate, unsafe trait-override getter, and rejected notification-preview code are absent.

The release preparation changes documentation, license attribution and GitHub
issue templates; the Swift sources, app resources, vendor engine, project
definition and build workflow match the verified 2.4.4 source. The supplied IPA
has public-safe compiler paths: the release copy redacts local build paths and
recomputes its existing ad-hoc signature/resource hashes. All executable and
data sections, entitlements, app resources and bundle IDs remain unchanged.
This is packaging work, not a new on-device test. A clean GitHub-hosted Xcode
run of the public repository has not been performed during this packaging pass.

The portable IPA provides nine manual icon choices. The source also includes
native any/dark/tinted asset-catalog artwork for Xcode builds. Automatic custom
dark/tinted artwork selection is not claimed for the portable package.

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

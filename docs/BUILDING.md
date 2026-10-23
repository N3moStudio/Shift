# Build Shift

The source includes the app, WidgetKit/Live Activity extension, tests, artwork,
helper source/downloads, Xcode project, and the bundled idevice engine library.
No Apple signing credentials or deployed helper are included.

## GitHub Actions — works from Windows

1. Upload the extracted repository using **GitHub Desktop**. Preserve `.github`, `Vendor`, `Shared`, and `LocusActivity`; put `project.yml` at the repository root.
2. Open **Actions → Build Shift IPA → Run workflow**. Choose the branch containing these files.
3. After the run succeeds, download **Shift 2.4.4.ipa** directly under Artifacts and sign it with SideStore. There is no extra ZIP to extract. Retain its extension. The filename automatically follows the app version in future builds.

The manual workflow uses GitHub’s `xcode-27` runner, verifies bundled helper
downloads, runs Python helper tests and Swift model tests, regenerates the
project with XcodeGen, then builds and checks both targets. Availability and
your account’s Actions quota apply. It does not publish a release or deploy a helper.

Start a **new run after pushing changes**. Re-running an older job uses its
original commit. Runner reference: [GitHub’s supported images](https://github.com/actions/runner-images#available-images).

## Local Mac

Use Xcode 27 and XcodeGen. From the repository root:

```sh
brew install xcodegen
swift test
bash scripts/build-ipa.sh
```

Output: `build/Shift <version>.ipa` (currently `build/Shift 2.5.0.ipa`).
The filename uses the built app’s version. The packager verifies the extension,
required resources, app-group entitlements, and appearance metadata. Its ad-hoc
signatures are placeholders; SideStore still needs to sign the installation.

`project.yml` is the project definition. Run `xcodegen generate` before opening
`Locus.xcodeproj` after source/configuration changes; the build script does this.
The checked-in project can be older than the generator input.

## Helpers and checks

```sh
python3 scripts/check_appearance.py
python3 scripts/check_app_identity.py
python3 scripts/package_helpers.py --check
python3 -m venv .venv
.venv/bin/python -m pip install -r CloudFindMy/requirements.txt
.venv/bin/python -m unittest discover -s Companion -p 'test_*.py' -v
.venv/bin/python -m unittest discover -s CloudFindMy -p 'test_*.py' -v
```

On Windows, use `.venv\Scripts\python.exe` for the virtual environment. After
changing helper source or guides, regenerate the in-app downloads with
`python3 scripts/package_helpers.py`, then check them again.

## Repository map

| Folder | Contents |
| --- | --- |
| `Locus/` | Shift’s SwiftUI app and connection/session engine |
| `Shared/` | App/extension models, appearance and status rules |
| `LocusActivity/` | Live Activities, Dynamic Island and widgets |
| `Companion/`, `CloudFindMy/` | Optional Windows and cloud helpers |
| `Tests/`, `scripts/` | Model tests, resource checks and packaging |
| `Brand/` | Current icon families and retained earlier brand assets |
| `Vendor/idevice/` | Existing static engine library, header and MIT notice |

The bundled engine is a prebuilt dependency, not a fresh build of the upstream
Rust source. Its upstream source is [idevice](https://github.com/jkcoxson/idevice).
No exact rebuild of that vendor binary is claimed here.

From 2.5.0, the app uses `com.n3mostudio.shift`, its extension uses
`com.n3mostudio.shift.activity`, and both share `group.com.n3mostudio.shift`.
Shift registers `shift://`; Locus keeps ownership of `locus://` links. This is a
separate installation from 2.4.x; follow [the migration checklist](TESTING-2.5.md).
Internal source/target names and serialized MPH fields remain compatible with
existing backups. `check_app_identity.py` verifies the source configuration; the
IPA validator checks the compiled bundle IDs and URL scheme.

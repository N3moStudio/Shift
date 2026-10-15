# Release Shift

Use one version throughout the app, release tag, notes and IPA filename.
The workflow builds the IPA; publishing a release is a separate, deliberate step.

## Current release

| Field | Value |
| --- | --- |
| App version / build | `2.4.4` / `47` |
| Git tag | `v2.4.4` |
| Release title | `Shift 2.4.4 — Finishing touches` |
| IPA filename | `Shift 2.4.4.ipa` |
| Release label | Stable; leave **Pre-release** unselected |
| Target | The finalized source commit on `main`, including the icon build fixes |
| Release body | [Copy the current notes](releases/v2.4.4.md), omitting their first title line |

For this release, the build and basic on-device use have been confirmed. The
working IPA's exact file and checksum have not been supplied for this documentation
update; do not reuse the checksum from the older portable package.

## Version numbers

Use this project convention, inspired by [Semantic Versioning](https://semver.org/):

| Change | Example next version | Tag |
| --- | --- | --- |
| Bug fixes or small refinements | `2.4.5` | `v2.4.5` |
| A substantial new feature with compatible existing behavior/data | `2.5.0` | `v2.5.0` |
| A release that breaks existing data, setup or helper compatibility | `3.0.0` | `v3.0.0` |
| Public test build | Numeric app version `2.5.0`; release marked beta | `v2.5.0-beta.1` |

The build number is a separate increasing integer: after `47`, use `48` for
the next new test/distribution build, then `49`, and so on. Increment it when
producing a new candidate, even if its public version has not changed. Documentation
edits and renaming an existing IPA do not need a new app build number.

For a beta, keep the app's numeric version in `project.yml` and use the beta
suffix in the Git tag/release title. Since the automatic filename uses the
numeric app version, label the beta attachment clearly before uploading, for
example `Shift 2.5.0-beta.1 (48).ipa`. Select **Pre-release** and do not make it Latest.

Once a version is publicly released, publish fixes under a new version/tag.
Do not move an existing release tag or silently replace its IPA with different code.

## Repeatable release process

1. **Prepare the version.** In `project.yml`, update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for both `Locus` and `LocusActivity`. XcodeGen regenerates the Xcode project during the build. Artifact names update automatically; do not hard-code a version in the workflow.
2. **Write the notes.** Add the changes to `CHANGELOG.md`, update the version references in `README.md` and `SETUP.md`, and copy [the release template](releases/TEMPLATE.md) to `docs/releases/vX.Y.Z.md`. Describe the changes since the last public release. Keep planned features out of shipped-feature lists.
3. **Commit and push.** Use a summary such as `Prepare Shift 2.4.5`. Start a new **Build Shift IPA** workflow on the intended branch; rerunning an older job uses its original commit.
4. **Save the build evidence.** Record the successful run URL, source commit, app/build versions and downloaded IPA filename. Read failed checks before retrying. Do not treat a successful build as a device test.
5. **Test that exact IPA.** Sign through SideStore and check clean launch, an update over an existing install when applicable, and all affected flows. Record the iPhone/iOS version, installation method, what passed and any remaining issue in `docs/TESTING.md`. The device checklist there covers the main flows.
6. **Freeze the candidate.** Keep the exact IPA you tested. If code, resources, dependencies or build behavior change, build and test the new candidate. Notes-only edits can follow without rebuilding; record the original build commit if the release tag also includes later documentation changes.
7. **Prepare attachments.** Use `Shift X.Y.Z.ipa`. A checksum file is recommended; calculate it from this exact file, after any packaging or signing changes. Do not copy a hash from another build with the same version.
8. **Create the draft.** On GitHub choose **Releases → Draft a new release**. Create tag `vX.Y.Z` at the finalized source commit, use `Shift X.Y.Z — Short description`, and paste the matching notes. If `main` has moved to unrelated changes, select the intended commit instead of its new tip.
9. **Attach and publish.** Attach the tested IPA and its checksum in the binaries/Assets area. Review the preview and filenames, then publish. Mark a stable release Latest when offered; mark beta/RC releases Pre-release. Download the published IPA once and compare its hash with the tested file.

Upload the IPA as an asset, not as a source-code commit. GitHub provides its
own source archives for the tag. Keep signing identities, device pairings,
Apple credentials and private helper data out of releases. Retain the extension
and third-party notices.

## Optional SHA-256 file on Windows

Run this in PowerShell after replacing the path with the exact IPA you tested:

```powershell
$releaseIpa = 'C:\path\to\Shift 2.4.4.ipa'
$releaseHash = (Get-FileHash -LiteralPath $releaseIpa -Algorithm SHA256).Hash.ToLowerInvariant()
$releaseName = [System.IO.Path]::GetFileName($releaseIpa)
"$releaseHash  $releaseName" | Set-Content -LiteralPath ($releaseIpa + '.sha256') -Encoding ascii
```

Attach both files. The checksum identifies those exact bytes; it does not
replace device testing or SideStore signing.

## Working links before publication

Use full GitHub documentation URLs pinned to an already-pushed commit when
preparing the release body. Those links work in draft previews and remain tied
to that source snapshot. A `blob/vX.Y.Z/...` URL works only after that tag exists
on GitHub; selecting a new tag in a draft does not make it available yet.

Open every documentation link before publishing. The current 2.4.4 notes use
commit `ff8d20436da5bdaade616f33bb3715cbbcaa0331`, which was already published
when the links were checked. The release can still use tag `v2.4.4`.

## Repository topics

These describe the project and are separate from version tags. Add them using
the repository's **About → gear → Topics**:

`ios`, `swift`, `swiftui`, `location-simulation`, `gps`, `mapkit`, `gpx`,
`route-planning`, `live-activities`, `dynamic-island`, `widgetkit`, `sidestore`.

Keep topics descriptive and stable; do not add a new topic for each release.

References: [GitHub release guide](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
and [repository topics](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics).

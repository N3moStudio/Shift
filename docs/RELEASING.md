# Prepare a release

1. Update both app/extension versions in `project.yml` and the artifact name in `.github/workflows/build-ipa.yml`.
2. Update `README.md`, `CHANGELOG.md` and the release description under `docs/releases/`.
3. Run the relevant tests, helper/appearance checks and a new IPA build. Test the affected flows on a device and state unverified behavior accurately.
4. Publish the source commit, create its matching release tag, and attach that build’s IPA plus SHA-256 checksum.

Keep signing identities, device pairings and private helper data out of source
and release assets. Do not strip the extension or third-party notices. The
supplied 2.4.4 release text is ready to paste; future versions need updated
validation, download names and hashes.

See [GitHub’s release guide](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

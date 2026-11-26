# Releasing

Releases are built locally (they need the iOS SDK, which xtool sets up) and published on GitHub.

## Channels

- **Releases** (`vX.Y.Z`, from `main`): what users install. Listed as "Latest" on GitHub.
- **Development builds** (`vX.Y.Z-beta.N`, from `develop`): for testers. Published as GitHub
  pre-releases, never marked latest.

Both are release-configuration builds (no test harness). The version scheme is
[Semantic Versioning](https://semver.org): patch for fixes, minor for features, major for changes
that break notebooks or backups.

## Steps

1. **Version.** On `develop`, set the new version and build number:

   ```bash
   scripts/release/bump-version.sh 1.1.0          # build number goes up by one
   ```

   The build number (`CFBundleVersion`) must go up with every published build, pre-releases included.
2. **Changelog.** Move the `[Unreleased]` items in `CHANGELOG.md` under a new `[X.Y.Z] - date` heading
   and update the links at the bottom. Pre-releases can use a `[X.Y.Z-beta.N]` heading.
3. **Test.** `NOTESCRAFT_CORE_ONLY=1 swift test`; on the iPad, the self test and the stress test
   (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)); a quick look at the screenshot tour.
4. **Merge** (releases only): merge `develop` into `main` and push both.
5. **Build:** `scripts/release/build-ipa.sh` writes `dist/NotesCraft-X.Y.Z.ipa` and its `.sha256`.
   The IPA is unsigned and contains no build-machine paths.
6. **Publish:** `scripts/release/publish.sh X.Y.Z` (or `X.Y.Z-beta.N`). It checks the tree is clean,
   tags the current commit, pushes the tag, and creates the GitHub release with the changelog
   section as notes and the IPA and checksum attached.
7. **Check** the release page, install the published IPA on an iPad, and bump `develop` to the next
   version when work starts.

## Hotfixes

Branch `fix/…` from `main`, fix, bump the patch version, release from `main` as above, then merge
`main` back into `develop`.

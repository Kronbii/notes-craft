# Contributing to NotesCraft

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting bugs and asking for features

- Bugs: use **Settings › Help and feedback › Report a problem** in the app (it fills in your version and device), or the [bug report form](https://github.com/Kronbii/notes-craft/issues/new?template=bug_report.yml).
- Ideas: the [feature request form](https://github.com/Kronbii/notes-craft/issues/new?template=feature_request.yml), or [Discussions](https://github.com/Kronbii/notes-craft/discussions) to talk it through first.
- Security problems: please don't open an issue; see [SECURITY.md](SECURITY.md).

## Branches and releases

- `main` holds released code only. Every release is a tag `vX.Y.Z` on `main`.
- `develop` is where work happens. Branch from it (`fix/…`, `feature/…`) and open pull requests against it.
- Development builds for testers are pre-release tags `vX.Y.Z-beta.N` on `develop`, published as GitHub pre-releases.
- A release merges `develop` into `main`. See [RELEASING.md](RELEASING.md).

## Setting up

You need:
- [xtool](https://github.com/xtool-org/xtool) 1.24 or later, set up once with `xtool setup` (an Apple ID; a free one works).
- An iPad with iPadOS 17 or later, connected by USB.
- For the core tests only: a Swift 6.2+ toolchain on Linux or macOS.

```bash
xtool dev run                         # debug build, installed and launched on the iPad
NOTESCRAFT_CORE_ONLY=1 swift test     # core unit tests (no iPad needed)
```

Debug builds define `NOTESCRAFT_DEV`, which adds the on-device test harness. Release builds (`xtool dev build --configuration release`) leave it out. Nothing behind `#if NOTESCRAFT_DEV` may be needed by the app itself.

## Testing a change

1. **Core tests** must pass: `NOTESCRAFT_CORE_ONLY=1 swift test` (CI runs them on every push and pull request).
2. **On the iPad**, with a debug build installed and the app open:
   - Copy your app's bundle ID into `scripts/dev/local.env` (see `scripts/dev/common.sh`).
   - `scripts/dev/tour.sh selftest` runs the built-in self test.
   - `scripts/dev/tour.sh stress 2400` runs the writing and erasing stress test.
   - `scripts/dev/tour.sh full 3000` takes screenshots of most screens in light and dark mode.

   See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for how this works.
3. **By hand** for anything the harness can't do: Apple Pencil writing feel, gestures, pickers, the microphone, the share sheet.

Describe what you tested in the pull request.

## Code

- Swift 6 language mode. The app target is main-actor by default; mark background work `nonisolated` or `@concurrent`.
- Keep `NotesCraftCore` free of UIKit, so it builds and tests on Linux.
- Follow the style of the code around you. Comments explain why, not what.
- User-facing text is short and plain.
- Never send user content anywhere; NotesCraft has no network features.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).

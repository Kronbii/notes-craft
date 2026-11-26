# NotesCraft

A free, open-source handwritten-notes app for iPad that combines the best of GoodNotes and Notability. Your notes stay on your iPad: no account, no cloud, nothing is sent anywhere.

**[Download the latest release](https://github.com/Kronbii/notes-craft/releases/latest)** · [What's new](CHANGELOG.md) · [Report a problem](https://github.com/Kronbii/notes-craft/issues/new/choose)

## Features

**Writing**
- Apple Pencil ink with PencilKit (low latency, pressure, tilt): ballpoint, fountain pen, brush, calligraphy (iPadOS 26), pencil, crayon and watercolor
- Highlighter that can snap to straight lines
- Stroke eraser and partial (pixel) eraser, optional "switch back after erasing"
- Scribble back and forth over writing to erase it (GoodNotes-style), as one undo step
- Draw and hold to turn a stroke into a perfect line, circle, ellipse, rectangle or triangle, plus a dedicated shapes tool
- Three favorite colors and three widths per tool, one tap away; tap a selected color or width again for the full palette
- Favorite pens: save a pen or highlighter setup (type, color, thickness) and switch to it with one tap
- Zoom window: write in a magnified strip at the bottom; the ink lands small and neat in a box on the page, moving along as you write
- Lasso: move, resize, recolor, copy, cut, duplicate, delete, share as image, and convert handwriting to text
- Text boxes with fonts, sizes, bold/italic/underline, colors, alignment and sticky-note fills
- Photos, camera shots and pasted images on the page
- Laser pointer for presenting
- Two-finger tap to undo, three-finger tap to redo (a short note says what was undone); Apple Pencil double-tap support
- Palm rejection: with Apple Pencil, fingers scroll and zoom (turn on "Draw with finger" if you have no Pencil)

**Notebooks and canvases**
- Notebooks: continuous vertical scrolling with crisp zoom at any level
- Canvases: a huge blank, dotted or grid space you pan and zoom freely (5% to 600%), with a minimap to find your way back
- Paper templates: blank, ruled (college, narrow, wide, legal), grid, fine grid, dotted, Cornell, checklist, music, in eight paper colors and A4/Letter/A5/B5/Legal/Square/16:9/iPad sizes
- Page sidebar with thumbnails: drag to reorder, duplicate, bookmark, change template, delete
- Import PDFs (including password-protected ones) and annotate them; insert PDF pages into any notebook
- Scan paper documents with the camera

**Audio (Notability-style)**
- Record lectures while you write; recording continues in the background
- Playback replays your ink in sync: ink written later appears faded and darkens as the audio reaches it
- Tap any ink to jump the audio to when it was written; 0.75× to 2× speed, skip ±15 s
- Transcripts: recordings become text on the iPad (nothing is uploaded); tap a sentence to hear it, and search what was said

**Library**
- Folders and subfolders with colors, drag and drop, favorites, recents, audio notes, and a 30-day trash
- Notebook covers in 14 colors and 6 patterns, or the first page as the cover
- Search across titles, typed text, PDF text, handwriting (recognized on-device) and recording transcripts
- Find inside a notebook with highlighted matches

**Export and backup**
- Share as PDF (vector ink by default), PNG images, or `.notescraft` notebooks (with audio) for another device
- Print
- One-tap full library backup to Files › On My iPad › NotesCraft › Backups (and weekly automatic backups), and restore
- Multiple windows: open two notebooks side by side with Split View or Stage Manager

## Install

NotesCraft is not on the App Store. You install it yourself ("sideloading") with a free Apple ID.

**Requirements:** an iPad with iPadOS 17 or later (calligraphy ink needs iPadOS 26). The app also installs on iPhone, but iPad is what it is made and tested for.

1. Download `NotesCraft-<version>.ipa` from the [latest release](https://github.com/Kronbii/notes-craft/releases/latest). Its SHA-256 checksum is published next to it.
2. Install it with one of these tools, which sign the app for your device with your Apple ID:
   - [xtool](https://github.com/xtool-org/xtool) (Linux, macOS, Windows/WSL): `xtool install NotesCraft-<version>.ipa`
   - [SideStore](https://sidestore.io) or [AltStore](https://altstore.io) (on the iPad, refreshes over Wi-Fi)
   - [Sideloadly](https://sideloadly.io) (macOS, Windows)
3. On the iPad, trust your developer certificate the first time: Settings › General › VPN & Device Management.

With a free Apple ID the signature lasts 7 days; reinstall (or refresh in SideStore/AltStore) before it expires. **Your notes are kept** when you reinstall or update, as long as you don't delete the app. Before deleting the app, make a backup in Settings › Backup.

## Help and feedback

In the app: Settings › Help and feedback.
- **Report a problem** opens a bug report with your app version, iPadOS version and device already filled in.
- **Copy diagnostics** copies those details plus how many notebooks you have (never their contents) to paste into a report.
- Questions and ideas: [Discussions](https://github.com/Kronbii/notes-craft/discussions). See [SUPPORT.md](SUPPORT.md).

Found a security problem? Please report it privately; see [SECURITY.md](SECURITY.md).

## Build from source

You need [xtool](https://github.com/xtool-org/xtool) (`xtool setup` once, with your Apple ID) and an iPad connected by USB.

```bash
xtool dev run                  # debug build: build, sign, install and launch
NOTESCRAFT_CORE_ONLY=1 swift test   # unit tests of the platform-independent core, on any host
scripts/release/build-ipa.sh   # release IPA in dist/
```

Debug builds include an on-device test harness (tours, stress test); release builds never do. See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Privacy

NotesCraft has no accounts, analytics or network features. Notebooks live in the app's private storage on your iPad. Handwriting recognition runs on the device. Backups and exports go only where you put them.

## License

[MIT](LICENSE)

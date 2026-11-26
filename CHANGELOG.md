# Changelog

All notable changes to NotesCraft are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-11-26

Three features from Notability and GoodNotes.

### Added
- **Transcripts of recordings.** When a recording stops, NotesCraft turns it into text on the iPad
  (Apple's on-device speech engine; nothing is uploaded, the language model is downloaded from Apple
  once). The transcript panel, opened from the audio player, highlights the sentence being played;
  tap any sentence to hear it. Copy a transcript, or transcribe again in another language.
  Find in a notebook and library search include what was said; a match plays from that moment.
  Settings › Recordings turns this on or off and sets the language.
- **Zoom window.** Write comfortably in a magnified strip at the bottom of the page; the ink lands
  small and neat inside a box on the page, at its real thickness. Drag the box, nudge it, or start a
  new line (it snaps to ruled lines). It moves along as you write and wraps at the margin.
  1.5× to 4×; erasing, scribble-to-erase and undo work inside it. Opens from the toolbar or the ⋯ menu.
- **Favorite pens.** Save the pen or highlighter you're using (type, color, thickness) and switch to
  it with one tap from the favorites bar left of the tools. Press and hold a favorite to move or
  remove it.

## [1.0.0] - 2026-11-26

The first release.

### Writing
- Apple Pencil ink with seven pen types (ballpoint, fountain, brush, calligraphy on iPadOS 26, pencil, crayon, watercolor), each with its own three thicknesses and three favorite colors.
- Highlighter with straight-line snapping; stroke and partial erasers.
- Scribble over writing to erase it.
- Draw-and-hold shape snapping and a shapes tool.
- Lasso selection: move, resize, recolor, copy, cut, duplicate, delete, share, convert handwriting to text.
- Text boxes with fonts, sizes, styles, colors, alignment and sticky-note fills; typing has its own undo.
- Images from Photos, the camera and the clipboard; laser pointer.
- Two-finger tap to undo and three-finger tap to redo, with a note saying what changed; pinches never count as taps.

### Notebooks and canvases
- Notebooks with continuous scrolling and many paper templates, colors and sizes.
- Canvases: a huge dotted, grid or blank space with GoodNotes-style dots, zoom from 5% to 600%, and a minimap with zoom level and "show everything".
- Page sidebar with thumbnails, reordering, bookmarks, templates and deletion.
- PDF import and annotation (including password-protected PDFs), PDF page insertion, document scanning.

### Audio
- Record while you write; playback replays your ink in sync; tap ink to jump to that moment.

### Library
- Folders, favorites, recents, audio notes, trash, covers.
- Search across titles, typed text, PDF text and handwriting (recognized on-device); find inside a notebook.

### Export and backup
- PDF (vector ink), PNG and `.notescraft` export; printing.
- Full library backup and restore, plus weekly automatic backups.

### App
- Light and dark appearance, multiple windows.
- Settings › Help and feedback: report a problem, suggest a feature, copy diagnostics.

[Unreleased]: https://github.com/Kronbii/notes-craft/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Kronbii/notes-craft/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Kronbii/notes-craft/releases/tag/v1.0.0

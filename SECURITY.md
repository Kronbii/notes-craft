# Security policy

## Supported versions

Security fixes go into the latest release. Please update to it before reporting.

| Version | Supported |
| ------- | --------- |
| 1.0.x   | Yes       |

## Reporting a vulnerability

Please **don't** open a public issue for security problems.

Report it privately through GitHub: on the [Security tab](https://github.com/Kronbii/notes-craft/security), choose **Report a vulnerability**. Include what you found, how to reproduce it, and which version and device you used.

You'll get a reply within a week. Once it's fixed, the fix ships in a new release and you'll be credited in the release notes, unless you'd rather not be.

## Scope

NotesCraft keeps everything on the device and has no network features, so the most relevant problems are:
- Opening a crafted file (`.notescraft` notebook, backup, PDF or image) that crashes the app, corrupts the library, or writes outside the app's storage.
- Data loss during saving, backup or restore.

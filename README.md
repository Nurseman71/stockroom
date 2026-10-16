# Stockroom

Local storage tracker (`index.html`) synced by `storage_tracker_server.py`, a
Python stdlib-only HTTP server. See that file's docstring for run
instructions.

## iPhone app (`ios/`)

A native SwiftUI app built for iPhone Duo (iOS 27+): list and box side by
side when unfolded, a single column when folded or in Split View. Open
`ios/Stockroom/Stockroom.xcodeproj` in Xcode 27 and run.

- Syncs with `storage_tracker_server.py` over its existing API — same
  `?token=` auth, same newest-`updatedAt`-wins merge, same `b_…` ids — so
  it and the web app share one data set.
- Works offline: edits and photos are cached on the phone and queued.
- Server address is entered in the app (HTTPS only); the sync token is kept
  in the iOS Keychain. Neither lives in this repo.
- Scans printed `?boxid=` labels to open a box; photos go through the
  server's Gemini identification, so no AI key is on the phone.

## Cross-project registry

This project's port (8787 by default) and its open questions (LaunchAgent
status, the referenced `media_vault_server.py`) are tracked in
`~/Jarvis/PROJECTS.md`, the shared registry of ports/launchd
services/API keys/shared files across every local project on this machine.
Check it before adding a new port or background service here, and update
this project's row in the same session as the change.

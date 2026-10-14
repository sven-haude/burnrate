# burnrate – notes for Claude

A small always-on-top macOS widget showing Claude Code and Codex usage limits, pace/projection and burn rate. Keep it a small helper: one Swift file, no dependencies, no build system.

## Layout

- `macos/Burnrate.swift` – the whole app (AppKit, single file). Sections: config → server data → pace → local logs → formatting → UI → widget.
- `macos/run.sh` – loads `config.env`, recompiles with `swiftc -O` when the Swift file is newer than the binary, then `exec`s it (used by launchd).
- `start.command` – (re)start via launchd if the autostart is installed, otherwise directly.
- `macos/install-autostart.sh` / `uninstall-autostart.sh` – LaunchAgent `com.github.sven-haude.burnrate`.
- `config.env` – all settings. The app reads them from the environment and exits with a clear error if one is missing. No hardcoded fallbacks in the code.
- `docs/*.png` – README screenshots of the widget window only.

## Run & check

```sh
swiftc -O macos/Burnrate.swift -o macos/.build/burnrate   # compile check
./start.command                                            # restart the widget
cat macos/burnrate.log                                     # stderr of the running widget
```

There are no tests. Verify UI changes with a screenshot of just the widget window:
look up its window number via `CGWindowListCopyWindowInfo` (owner name `burnrate`) and run `screencapture -x -o -l <id> out.png`.
Force English for a run with `./macos/.build/burnrate -AppleLanguages '(en)'` (after sourcing `config.env`).

## Things that bite

- **Rate limit:** the Claude usage endpoint allows roughly one request every 1–2 minutes per login. Every start fetches immediately, so restarting several times in a row shows "429". Space test runs ~2 minutes apart, or test layout with Claude hidden (`CLAUDE_PROJECTS_DIR=/nonexistent CLAUDE_USAGE_KEYCHAIN_SERVICE=none`).
- **Undocumented endpoints:** `api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`) and `chatgpt.com/backend-api/wham/usage`. Parse defensively and show a warning in the widget instead of crashing.
- **Tokens:** read from the macOS Keychain (`Claude Code-credentials`) and `~/.codex/auth.json`. Never refresh them – that would rotate the refresh token under the CLI's feet.
- **Memory:** the local logs are ~1 GB per week with single lines over 1 MB. The scanner reads in 1 MB chunks into a reused buffer, extracts fields with `memmem` instead of parsing whole lines as JSON, and keeps events as compact 32-byte structs. Target footprint is ~35 MB (`footprint <pid>`); don't regress this.
- **Dedup:** Claude Code writes one log line per content block with the same message id (last one wins); Codex repeats `token_count` events with identical totals.
- **UserDefaults domain is the binary name** (`burnrate`): `mode` (mini/compact/details), `positionX`/`positionY`, `showCodex` (bool, default true; off = no fetch, no log scan, no section).

## Conventions

- UI strings go through `t("Deutsch", "English")` – German on German systems, English otherwise.
- Code comments are German, user-facing docs (README) English.
- Branches: `user/shaude/<topic>`, PRs squash-merged into `main`.

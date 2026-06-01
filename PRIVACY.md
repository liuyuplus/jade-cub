# Privacy

Last updated: 2026-06-01

Jade Cub is a local-first macOS app. By default, it does not include product analytics, telemetry, advertising SDKs, or a hosted backend for collecting user data.

## Data Read Locally

Depending on which features you enable, Jade Cub may read local data such as:

- Agent hook events and session metadata from supported coding tools.
- Codex app-server or rollout data needed to show live Codex session status.
- Local transcript/session files for clients that expose them, such as OpenClaw.
- Terminal, tmux, and IDE window metadata used for jump-back and focus actions.
- Optional Obsidian vault, daily note, template, and filename pattern paths that you configure.
- Optional now-playing metadata from Music, Spotify, or NeteaseMusic for local UI display.
- Local app settings, sound-pack choices, mascot overrides, and cached session state.

## Network Use

Jade Cub does not upload your notes, transcripts, prompts, or session content to a Jade Cub service.

Network activity can happen when you explicitly use or configure features that require it:

- Sparkle/GitHub update checks may request release metadata and appcast files.
- Remote SSH bridge workflows, currently hidden from the default settings panel, connect to user-provided hosts and can copy bridge or hook files to those hosts.
- GitHub release assets may be downloaded when the remote bridge bootstrap needs a platform-specific bridge binary.

## Storage

Jade Cub stores normal app preferences in macOS `UserDefaults` and app support/cache locations. Optional SSH passwords for remote bridge sessions are stored in the macOS Keychain when that remote feature is used. Obsidian integration settings store only the paths and filename pattern you choose, not your note contents.

## Diagnostics

Diagnostics export is user-initiated. Review exported files before sharing them publicly, because local paths, session names, or tool metadata may appear in diagnostic output.

## Obsidian

The Obsidian daily-task feature is optional. It reads the Markdown files under the paths you configure so Jade Cub can show daily task progress locally. The public source repository uses placeholder paths and does not include any personal vault path.

## Contact

For privacy or security issues, open a GitHub issue in the Jade Cub repository or contact the maintainer through the repository profile.

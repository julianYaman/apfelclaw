<div align="center">

<img src="site/public/apfelclaw.png" alt="apfelclaw logo" width="128" />

<h1>apfelclaw</h1>

<blockquote align="left"><b>Disclaimer: </b>This project is in very early development. It is not intended for production use or real-world tasks and is provided for experimental purposes only. Use it at your own risk. We are not liable for any security issues, data loss, or other damages resulting from its use.</blockquote><br />

<p><code>apfelclaw</code> is a locally running AI agent for tasks with macOS using Apple's Foundation model via <a href="https://github.com/Arthur-Ficial/apfel">apfel</a>.</p>

<video src="site/public/apfelclaw-showcase.mp4" controls width="100%"></video>

</div>

The repository is organized as a small monorepo:

- `packages/apfelclaw-server`: Swift backend runtime, local API, tool execution, and persistence
- `apps/cli`: Node-based `apfelclaw` command tool with onboarding and lifecycle commands
- `apps/tui`: Separate chat application
- `apfelclaw`: convenience launcher for the Node CLI in this repo

## Status

This project currently targets Apple Silicon Macs running macOS 26 Tahoe or newer. It depends on Apple platform APIs such as EventKit, Apple Mail, and Spotlight-backed file search, and it expects `apfel` to be installed locally for model execution.

## Install with Homebrew

```bash
brew tap julianYaman/apfelclaw
brew install apfelclaw
```

The Homebrew formula can install the Node-based `apfelclaw` command tool, the separate chat app, and the Swift backend runtime together.

## Prerequisites

- macOS 26 Tahoe or newer
- Node.js 18+
- Bun 1.0+ for local chat development or source builds
- Swift 6.3+ for backend development or source builds
- `apfel` installed and available on `PATH`

apfelclaw inherits the same macOS baseline as `apfel`, because model execution is delegated to the local `apfel` server.

## Run locally

1. Install workspace dependencies:

```bash
bun install
```

2. Run the CLI and complete onboarding:

```bash
./apfelclaw
```

The CLI runs the onboarding flow, can optionally set up Telegram remote control, and starts the backend in the background.

This launcher script runs the Node `apfelclaw` command tool from the repo root.

3. If you want to run the chat app from source during development:

```bash
cd apps/tui
bun install
```

4. Start the TUI client:

```bash
bun run dev
```

Or use the chat command through the CLI:

```bash
./apfelclaw chat
```

You can also use the root scripts:

```bash
./apfelclaw
./apfelclaw serve
./apfelclaw chat
npm run dev:server
npm run dev:tui
```

The backend keeps using `apfel` for model execution.

## CLI commands

- `apfelclaw`: onboarding on first run, then help and local status
- `apfelclaw setup`: re-run the onboarding guide
- `apfelclaw serve`: run the backend in the foreground
- `apfelclaw chat`: launch the terminal chat client when the backend is already running
- `apfelclaw stop`: stop the managed backend
- `apfelclaw --status`: print backend, apfel, and remote-control status
- `apfelclaw --update`: update apfelclaw and Homebrew-managed apfel

## Development

API endpoints:

- `GET /health`
- `GET /status`
- `GET /config`
- `PATCH /config`
- `GET /tools`
- `GET /sessions`
- `POST /sessions`
- `GET /sessions/:id/messages`
- `POST /sessions/:id/messages`
- `GET /sessions/:id/stream` WebSocket stream for live session events

HTTP response headers:

- `Server: apfelclaw/0.2.0`

Config API:

- `GET /config` returns flat global app config JSON:

```json
{
  "assistantName": "Apfelclaw",
  "userName": "You",
  "approvalMode": "trusted-readonly",
  "debug": false
}
```

- `PATCH /config` accepts the same flat keys as optional fields and returns the updated config.
- Supported `approvalMode` values are `always`, `ask-once-per-tool-per-session`, and `trusted-readonly`.
- `debug` is a boolean global flag for backend debug logging.
- Empty or whitespace-only names are rejected. Name fields are trimmed and capped at 80 characters.

## Contributor notes

- Config lives in `~/.apfelclaw/config.json` and persists across server restarts.
- Install state lives in `~/.apfelclaw/state.json`.
- SQLite memory lives in `~/.apfelclaw/memory.sqlite`.
- The current TUI is the first client; other clients can target the same local API later.
- `Ctrl+C` triggers a graceful server shutdown before process exit.
- The backend version is defined in Swift and is used for both the system prompt and the `Server` response header.
- When `debug` is `true`, the server prints each HTTP request, the `IntentRouter` decision for chat turns, and tool call arguments and results.
- Runtime tools are defined in [`packages/apfelclaw-server/TOOLS.md`](packages/apfelclaw-server/TOOLS.md) and in the JSON catalog under `Sources/ApfelClawCore/Resources/tools.json`.

## Contributing

Contribution guidelines live in [`CONTRIBUTING.md`](CONTRIBUTING.md). Please read that file before opening a pull request.

## License

This project is available under the MIT License. See [`LICENSE`](LICENSE).

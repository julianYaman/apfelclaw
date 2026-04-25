<div align="center">

<img src="site/public/apfelclaw.png" alt="apfelclaw logo" width="128" />

<h1>apfelclaw</h1>

<blockquote align="left"><b>Disclaimer: </b>This project is in very early development. It is not intended for production use or real-world tasks and is provided for experimental purposes only. Use it at your own risk. We are not liable for any security issues, data loss, or other damages resulting from its use.</blockquote><br />

<p><code>apfelclaw</code> is a locally running AI agent for tasks with macOS using Apple's Foundation model via <a href="https://github.com/Arthur-Ficial/apfel">apfel</a>.</p>

<video src="site/public/apfelclaw-showcase.mp4" controls width="100%"></video>

</div>

The repository is organized as a small monorepo:

- `packages/apfelclaw-server`: Swift backend runtime, local API, tool execution, and persistence
- `apps/tui`: OpenTUI client built with Bun
- `apfelclaw`: convenience launcher for the backend server

## Status

This project is currently macOS-only. It depends on Apple platform APIs such as EventKit, Apple Mail, and Spotlight-backed file search, and it expects `apfel` to be installed locally for model execution.

## Prerequisites

- macOS 26 Tahoe or newer
- Swift 6.3+
- Bun 1.0+
- `apfel` installed and available on `PATH`

apfelclaw inherits the same macOS baseline as `apfel`, because model execution is delegated to the local `apfel` server.

## Run locally

1. Start the backend server:

```bash
./apfelclaw
```

The server listens on `127.0.0.1:4242`.

This launcher script starts the Swift server package from the repo root.

2. In a second terminal, install the TUI dependencies:

```bash
cd apps/tui
bun install
```

3. Start the TUI client:

```bash
bun run dev
```

You can also use the root scripts:

```bash
./apfelclaw
npm run dev:server
npm run dev:tui
```

The backend keeps using `apfel` for model execution.

## Development

API endpoints:

- `GET /health`
- `GET /config`
- `PATCH /config`
- `GET /tools`
- `GET /sessions`
- `POST /sessions`
- `GET /sessions/:id/messages`
- `POST /sessions/:id/messages`
- `GET /sessions/:id/stream` WebSocket stream for live session events

HTTP response headers:

- `Server: apfelclaw-server/0.2.0`

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

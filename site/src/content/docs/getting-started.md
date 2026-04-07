---
title: Getting Started
description: Install prerequisites, start the backend server, and connect the TUI client.
order: 1
---

## Prerequisites

Before running apfelclaw, make sure you have the following installed:

- **macOS 13** or newer
- **Swift 6.3+**
- **Bun 1.0+**
- **apfel** installed and available on your `PATH` ([github.com/Arthur-Ficial/apfel](https://github.com/Arthur-Ficial/apfel))

apfelclaw depends on Apple platform APIs (EventKit, Apple Mail, Spotlight) and uses `apfel` for on-device model execution. It is macOS-only.

## Project structure

The repository is organized as a small monorepo:

| Path | Description |
|---|---|
| `packages/apfelclaw-server` | Swift backend runtime — local API, tool execution, conversation management, and persistence |
| `apps/tui` | Terminal UI client built with [OpenTUI](https://opentui.dev) and Bun |
| `./apfelclaw` | Convenience launcher script for the backend server |

## Start the backend server

From the repository root:

```bash
./apfelclaw
```

The server starts listening on `127.0.0.1:4242`. This launcher script builds and runs the Swift server package.

## Install TUI dependencies

In a second terminal:

```bash
cd apps/tui
bun install
```

## Start the TUI client

```bash
bun run dev
```

You should now see the terminal interface connected to your local backend.

## Alternative: root scripts

You can also use the convenience scripts from the repo root:

```bash
./apfelclaw          # start backend server
npm run dev:server   # alternative server start
npm run dev:tui      # start TUI client
```

## Configuration

Config lives in `~/.apfelclaw/config.json` and persists across server restarts. SQLite memory is stored at `~/.apfelclaw/memory.sqlite`.

A typical config looks like:

```json
{
  "assistantName": "Apfelclaw",
  "userName": "You",
  "approvalMode": "trusted-readonly",
  "debug": false
}
```

See the [API Reference](/docs/api) for details on reading and updating config via the REST API.

Remote control providers store their own state separately in `~/.apfelclaw/remote-control.json`.

## What's next

- Browse the [API Reference](/docs/api) for endpoint details
- See [Connections](/docs/connections) for remote access options like Telegram
- See available [Tools](/docs/tools) and what the agent can do
- Learn how the [Intent Router](/docs/intent-router) decides when to use a tool

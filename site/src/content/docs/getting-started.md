---
title: Getting Started
description: Install apfelclaw, complete onboarding, and launch the separate chat app.
order: 1
---

## Prerequisites

Before running apfelclaw, make sure you have the following installed:

- **macOS 26 Tahoe** or newer on Apple Silicon
- **apfel** installed and available on your `PATH` ([github.com/Arthur-Ficial/apfel](https://github.com/Arthur-Ficial/apfel))

apfelclaw depends on Apple platform APIs (EventKit, Apple Mail, Spotlight) and uses `apfel` for on-device model execution. It is macOS-only, and its effective runtime requirement matches `apfel`. Homebrew installs also bring in the Node runtime used by the `apfelclaw` command tool.

## Install with Homebrew

```bash
brew tap julianYaman/apfelclaw
brew install apfelclaw
```

The current release target is Apple Silicon on macOS Tahoe (macOS 26) or newer.

## Project structure

The repository is organized as a small monorepo:

| Path | Description |
|---|---|
| `packages/apfelclaw-server` | Swift backend runtime — local API, tool execution, conversation management, and persistence |
| `apps/cli` | Node-based `apfelclaw` command tool with onboarding, status, updates, and service lifecycle |
| `apps/tui` | Separate terminal chat application built with [OpenTUI](https://opentui.com) |
| `./apfelclaw` | Convenience launcher script for the Node CLI in this repo |

## Run onboarding

After installation, run:

```bash
apfelclaw
```

The first run asks for your basic config, starts the backend automatically, and can optionally set up Telegram remote control.

If you later need a foreground backend manually, run:

```bash
apfelclaw serve
```

## Launch the chat app

Once the backend is already running:

```bash
apfelclaw chat
```

If the backend is down, `apfelclaw chat` tells you to run `apfelclaw serve`.

You should now see the separate chat application connected to your local backend.

The TUI header will show a passive `apfel` update indicator when a newer version is available.

## Development commands

If you are working from a source checkout, you can also use the convenience scripts from the repo root:

```bash
./apfelclaw          # onboarding or help/status
./apfelclaw serve    # foreground backend
./apfelclaw chat     # launch chat client
npm run dev:server   # alternative foreground backend
npm run dev:tui      # start TUI client from source
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

When the assistant needs fresh local or personal data, it may ask for a clarification instead of guessing.

Remote control providers store their own state separately in `~/.apfelclaw/remote-control.json`. Onboarding state is stored in `~/.apfelclaw/state.json`.

## Apfel updates

apfelclaw checks in the background whether your installed `apfel` binary is current.

- Homebrew installs compare against the Homebrew formula version
- Other installs compare against the latest GitHub release
- `/version` shows the current backend and `apfel` version status
- `/apfel status` shows detailed `apfel` version, update, and maintenance information
- `/apfel restart` and `/apfel upgrade` are explicit commands that require a second `confirm` command before running

## What's next

- Try [Starter Prompts](https://bearprompt.com/prompts/apfelclaw) for a few ready-made ways to start using apfelclaw
- Browse the [API Reference](/docs/api) for endpoint details
- See [Connections](/docs/connections) for remote access options like Telegram
- See available [Tools](/docs/tools) and what the agent can do
- Learn how the [Intent Router](/docs/intent-router) decides when to use a tool

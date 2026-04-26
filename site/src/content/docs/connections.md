---
title: Connections
description: Remote connection options for talking to apfelclaw beyond the local TUI.
order: 4
section: Connections
---

apfelclaw runs as a local backend on your Mac, but it can also expose controlled remote entry points through connection providers.

## Current connection providers

- [Telegram](/docs/connections/telegram) — private bot access with one approved Telegram account and one linked private chat

## Design goals

Connections are intended to keep the same core behavior as the local TUI:

- The backend still owns sessions, routing, tools, and persistence
- Remote messages still flow through the same `IntentRouter` and tool execution path
- The configured `assistantName` is reused across clients
- The local CLI and TUI can both drive setup and status, but the backend keeps running after setup

## Security model

Remote connections should stay narrow and explicit.

For the current Telegram integration, apfelclaw only accepts:

- a single approved private chat
- a single approved Telegram user ID

Other Telegram chats and other Telegram accounts are ignored.

## Local setup flow

Remote providers can be configured during first-run onboarding or later from the TUI with `/remotecontrol` commands.

Typical flow:

1. Run `./apfelclaw` and optionally complete Telegram setup during onboarding
2. Or, if the backend is already running, open the TUI with `./apfelclaw chat` or `bun run dev`
3. Run `/remotecontrol setup telegram <botToken>`
4. Send a private message to the Telegram bot
5. Run `/remotecontrol status telegram` to confirm the approved chat and user

## What's next

- Read the [Telegram](/docs/connections/telegram) guide for the full setup flow
- See the [API Reference](/docs/api) for the local endpoints that back the TUI onboarding flow

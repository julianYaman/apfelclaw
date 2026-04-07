---
title: Telegram
description: Connect apfelclaw to a private Telegram bot and control it remotely.
order: 5
section: Connections
---

The Telegram connection lets you write to apfelclaw remotely through a private Telegram bot while the backend continues running locally on your Mac.

## What it supports

- Private bot chats only
- One approved Telegram account
- One linked private Telegram chat
- Automatic tool execution using the Telegram provider's current settings
- Shared slash commands such as `/new`, `/help`, `/version`, `/config`, and `/config set ...`

After setup, Telegram can keep talking to apfelclaw even when the TUI is closed.

## Prerequisites

- The backend is running locally with `./apfelclaw`
- The TUI is available for onboarding
- You have created a Telegram bot with BotFather and have a bot token

## Setup

Run this inside the TUI:

```text
/remotecontrol setup telegram <botToken>
```

apfelclaw verifies the bot token and starts Telegram linking mode.

Next:

1. Send a private message to your Telegram bot
2. Return to the TUI
3. Run:

```text
/remotecontrol status telegram
```

The status output should show:

- `enabled: true`
- `pollingEnabled: true`
- `approvedChatID: ...`
- `approvedUserID: ...`

That means the provider is linked to one private chat and one Telegram user account.

## Useful TUI commands

```text
/remotecontrol
/remotecontrol status telegram
/remotecontrol disable telegram
/remotecontrol reset telegram
```

## Telegram commands

Once linked, the Telegram chat can use the shared command layer:

- `/new` starts a fresh session for the linked Telegram chat
- `/help` shows supported commands
- `/version` shows the backend version
- `/config` shows the current config
- `/config set ...` updates the editable config fields

Example:

```text
/config set assistantName Orbit
```

## Runtime behavior

The backend owns the Telegram poller. That means:

- setup happens from the TUI
- message handling happens in the backend
- Telegram shows a typing indicator while the backend is working on a normal chat request
- Telegram continues to work after the TUI is closed

## Storage

Telegram remote control state is persisted locally:

- Global app config: `~/.apfelclaw/config.json`
- Remote control config: `~/.apfelclaw/remote-control.json`
- Session memory and remote chat mappings: `~/.apfelclaw/memory.sqlite`

## Security notes

The current Telegram integration is intentionally narrow:

- only private chats are accepted
- only the approved chat ID is accepted
- only the approved Telegram user ID is accepted

If you reset Telegram remote control, the stored approval and local session mapping are cleared.

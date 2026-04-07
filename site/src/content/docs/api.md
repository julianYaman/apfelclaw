---
title: API Reference
description: REST endpoints, WebSocket streaming, config API, and response headers.
order: 2
---

The apfelclaw backend exposes a local REST API on `127.0.0.1:4242`. All endpoints are unauthenticated and intended for local use only.

## Response headers

Every HTTP response includes:

```
Server: apfelclaw-server/0.1.0
```

## Endpoints

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/health` | Health check |
| `GET` | `/config` | Read current configuration |
| `PATCH` | `/config` | Update configuration fields |
| `GET` | `/tools` | List available tools |
| `GET` | `/sessions` | List all sessions |
| `POST` | `/sessions` | Create a new session |
| `GET` | `/sessions/:id/messages` | Get messages for a session |
| `POST` | `/sessions/:id/messages` | Send a message to a session |
| `WS` | `/sessions/:id/stream` | WebSocket stream for live session events |

## Config API

### `GET /config`

Returns the current global configuration as a flat JSON object:

```json
{
  "assistantName": "Apfelclaw",
  "userName": "You",
  "approvalMode": "trusted-readonly",
  "debug": false
}
```

### `PATCH /config`

Accepts any subset of the config fields as optional keys and returns the updated config. Validation rules:

- Empty or whitespace-only names are rejected
- Name fields are trimmed and capped at 80 characters
- `debug` is a boolean flag that enables verbose backend logging (HTTP requests, IntentRouter decisions, tool call arguments and results)

### Approval modes

The `approvalMode` field controls when the user is prompted before a tool runs:

| Value | Behavior |
|---|---|
| `always` | Prompt before every tool call |
| `ask-once-per-tool-per-session` | Prompt on the first use of each tool per session |
| `trusted-readonly` | Never prompt — all tools are read-only |

## Sessions API

### `POST /sessions`

Creates a new conversation session. Returns the session object with an `id` field.

### `GET /sessions/:id/messages`

Returns the message history for the given session.

### `POST /sessions/:id/messages`

Sends a user message to the session. The backend will route the message through the [Intent Router](/docs/intent-router), optionally invoke a [tool](/docs/tools), and return the assistant's response.

## WebSocket stream

### `WS /sessions/:id/stream`

Opens a WebSocket connection for real-time session events. Events are pushed as the backend processes messages, including tool approval requests, tool results, and assistant responses.

This is used by the TUI client to provide a live, streaming experience. Other clients can connect to the same endpoint.

## Storage

- Config: `~/.apfelclaw/config.json`
- Memory: `~/.apfelclaw/memory.sqlite`

Both persist across server restarts. `Ctrl+C` triggers a graceful shutdown before process exit.

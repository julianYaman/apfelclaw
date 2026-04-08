---
title: Tools
description: Tool catalog — file search, file info, calendar events, Mac status, safe commands, and recent mail.
order: 3
---

apfelclaw loads its runtime tool catalog from a JSON manifest (`tools.json`). The model does not read this file directly — the app converts it into an OpenAI-compatible `tools` payload, sends that to `apfel`, and maps approved tool calls back to local Swift executors.

All current tools are **read-only**. Whether the user is prompted before execution depends on the configured [approval mode](/docs/api#approval-modes) and each tool's confirmation policy.

## find_files

Find files on this Mac using Spotlight-backed search.

| Property | Value |
|---|---|
| Domain | `files` |
| Read-only | Yes |
| Follow-up reuse | No |

**Parameters:**

| Name | Type | Required | Description |
|---|---|---|---|
| `query` | string | Yes | Search phrase or filename |
| `limit` | integer | No | Maximum results (prefer 5 or fewer) |

**Use when:** The user needs to locate files by name or search phrase.

**Avoid when:** The user already has an exact absolute path — use `get_file_info` instead.

**Examples:**
- "Find my resume"
- "Where is the project proposal?"
- "Search for files named budget"

---

## get_file_info

Get metadata for one exact file or directory path, including paths that start with `~/`.

| Property | Value |
|---|---|
| Domain | `files` |
| Read-only | Yes |
| Follow-up reuse | No |

**Parameters:**

| Name | Type | Required | Description |
|---|---|---|---|
| `path` | string | Yes | Exact file or directory path. Prefer an absolute path; `~/...` is also supported |

**Use when:** The user already provided the exact path and wants metadata (size, dates, type).

**Avoid when:** The user needs to search for the path first — use `find_files` instead.

**Examples:**
- "What's in ~/Documents/report.pdf?"
- "Get info on /Applications/Xcode.app"

---

## list_calendar_events

Read upcoming events from the user's calendars via EventKit.

| Property | Value |
|---|---|
| Domain | `calendar` |
| Read-only | Yes |
| Follow-up reuse | Yes |
| Deterministic fallback | No |

**Parameters:**

| Name | Type | Required | Description |
|---|---|---|---|
| `timeframe` | string | Yes | Natural-language time range such as `today`, `tomorrow`, `next week`, `April 12`, or `2026-04-12` |
| `limit` | integer | No | Maximum events (prefer 10 or fewer) |

**Use when:** The user asks about meetings or schedule items for a specific time range.

**Avoid when:** The user wants to create or edit events.

**Examples:**
- "What meetings do I have today?"
- "Show my schedule for tomorrow"
- "Any events this week?"

> This tool supports **follow-up reuse**: if the user asks about "today" and then follows up with "what about tomorrow?", the Intent Router can reuse this tool without re-classifying from scratch.

---

## get_mac_status

Read current status information from this Mac.

| Property | Value |
|---|---|
| Domain | `system` |
| Read-only | Yes |
| Follow-up reuse | Yes |
| Deterministic fallback | Yes |

**Parameters:**

| Name | Type | Required | Description |
|---|---|---|---|
| `sections` | array | No | Optional section list. Allowed values: `battery`, `power`, `thermal`, `memory`, `storage`, `uptime`. Omit for an overview |

**Use when:** The user asks about this Mac's current battery, power, thermal state, memory, disk space, or uptime.

**Avoid when:** The question is about files, calendar, mail, or requires a shell command rather than direct system status APIs.

**Examples:**
- "How much battery do I have left?"
- "What's my Mac status?"
- "How much free disk space do I have?"

> This tool supports **follow-up reuse**: if the user first asks for an overview and then follows up with a narrower system-health question, the router can reuse this tool.

---

## run_safe_command

Run one read-only native macOS terminal command from the safe allowlist.

| Property | Value |
|---|---|
| Domain | `terminal` |
| Read-only | Yes |
| Follow-up reuse | No |

**Parameters:**

| Name | Type | Required | Description |
|---|---|---|---|
| `command` | string | Yes | Command name from the allowlist |
| `arguments` | array | No | Array of string arguments. Each command has its own safe argument rules |

**Use when:** A single allowlisted read-only shell command directly answers the question.

**Avoid when:** The task needs shell syntax, write access, or commands not on the list.

### Safe command allowlist

The following commands are permitted:

`pwd` `ls` `whoami` `date` `mdfind` `mdls` `stat` `find` `ps` `lsof`

**Examples:**
- "What's my username?"
- "List files in my Downloads folder"
- "Show running processes"

---

## list_recent_mail

Read recent messages from the Apple Mail inbox.

| Property | Value |
|---|---|
| Domain | `mail` |
| Read-only | Yes |
| Follow-up reuse | Yes |
| Deterministic fallback | Yes |

**Parameters:**

| Name | Type | Required | Description |
|---|---|---|---|
| `limit` | integer | No | Maximum messages (prefer 5 or fewer) |

**Use when:** The user asks for latest or recent emails.

**Avoid when:** The user asks for specific mail search, message bodies, or mail actions.

**Examples:**
- "Check my email"
- "Any new mail?"
- "Show me the last 3 emails"

> This tool supports **follow-up reuse**: if the user asks "any new mail?" and then follows up with "show me more", the router can reuse this tool.

---

## Tool behavior notes

### Argument normalization

Each tool module validates the model's raw argument JSON before execution. Unexpected keys and missing required parameters are rejected instead of being guessed from the user's message. Optional limits are still clamped to safe ranges.

### Result snapshots

After execution, each tool can produce a `ToolResultSnapshot` — a structured summary of what the tool covered. This snapshot includes:

- **scopeSummary**: A human-readable description (e.g., "Previous calendar lookup covered today (2026-04-07) and returned 3 event(s).")
- **machineReadableScope**: A JSON object the router uses to compare previous vs. requested scope

These snapshots are injected into the [Intent Router's](/docs/intent-router) context for subsequent turns, helping it decide whether to reuse a tool or pick a different one.

### Deterministic fallback

Tools marked with "deterministic fallback" (`list_recent_mail`) can be invoked with empty `{}` arguments when the model fails to produce valid arguments but routing has already decided a tool should run.

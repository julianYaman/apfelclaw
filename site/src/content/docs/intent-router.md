---
title: Intent Router
description: How apfelclaw decides when to use a tool — a single-stage, model-driven classifier.
order: 6
---

The Intent Router is the decision-making core of apfelclaw. On every user message, it chooses exactly one tool name or decides to answer without a tool. Rather than relying on keyword matching or hardcoded trigger phrases, it uses model-driven intent classification.

Classifier calls go to `apfel` with `response_format: json_schema` and `temperature: 0` (greedy). The schema enumerates the live tool catalog, which constrains the small on-device model to one allowed tool name or `null`. User-facing replies still use `temperature: 0.2` and a larger `max_tokens` budget.

## Overview

The router runs **one classification stage**. If that output is empty, unparseable, or names a tool that is not registered, it retries once. If both attempts fail, it asks for clarification instead of guessing.

```
User message
    │
    ▼
┌─────────────────────┐
│  Classify            │──── valid tool name ──▶ Done (use tool)
└─────────────────────┘
    │
    ├── toolName is null ──▶ Answer directly
    │
    └── invalid after retry ──▶ Ask for clarification
```

Argument filling, approval, execution, and result formatting happen after this decision. The router never emits tool arguments.

## Classifier

The classifier asks the model for a single field:

```json
{ "toolName": "list_calendar_events" }
```

or, when no tool is needed:

```json
{ "toolName": null }
```

The model receives:

- A system prompt listing all registered tools with their **domain**, **purpose**, **use_when**, **avoid_when**, **examples**, and **returns**
- The current **reference date and timezone** with explicit labels ("Today means 2026-04-07", "Tomorrow means 2026-04-08")
- A summary of the **last tool call** (if any), including its scope snapshot and whether follow-up reuse is allowed
- The **last 4 messages** of conversation context
- A compact rolling **session summary** when memory is enabled
- The latest **user message**

The same stage also routes calendar write requests. For example, a message like "Add my weekly sync meeting for today at 14:00 to my calendar" should select `add_calendar_event`.

Follow-ups are classified in this same pass. If the previous calendar lookup covered today and the user says "what about tomorrow?", the last-tool snapshot and a few follow-up examples are enough for the model to select `list_calendar_events` again.

## Follow-up reuse

Follow-up reuse is prompt context, not a second model call. When a recent approved tool call exists, the classifier sees:

- **toolName** and **domain**
- **followUpReuse** — `yes` for read-only lookups that can be repeated with a changed scope; `no` for write tools and other tools that should not be repeated from a vague follow-up
- A **scope snapshot** of what the previous result covered

Currently, `list_calendar_events`, `list_recent_mail`, and `get_mac_status` allow follow-up reuse. `add_calendar_event` does not, because reusing write-capable tools is riskier than reusing read-only lookups. File and terminal tools do not.

The classifier is instructed to pick the same tool again only when that last tool allows follow-up reuse and the user is asking for a changed or fresh scope of the same lookup. A write-tool follow-up such as "add a dentist appointment at 3pm" after a calendar listing should select `add_calendar_event`, not reuse the list tool.

## Retry mechanism

The classifier tries **twice**, because a schema-valid object can still name an unknown tool:

1. **Normal attempt** — guided `json_schema` generation
2. **Strict retry** — if the first attempt is empty, unparseable, or names a tool that is not registered, the prompt is augmented with: "Previous output was invalid. Retry and return exactly one JSON object matching the schema."

If both attempts fail, the router asks for clarification rather than guessing. A valid `null` tool name is trusted in one pass, including after an earlier tool-backed turn.

## Context assembly

The classifier prompt is built from several sources:

### Tool registry

The router reads from each tool module's routing metadata:

- **domain** — semantic grouping (e.g., `files`, `calendar`, `mail`, `terminal`)
- **purpose** — what the tool does
- **use_when / avoid_when** — guidance for the model
- **examples** — natural-language trigger phrases
- **returns** — what the tool's output contains

The JSON schema's `toolName` enum is generated from the same registry, so the model cannot name a tool that is not loaded.

### Last tool call summary

When a tool was used in a recent turn, the router injects a `ToolResultSnapshot`:

- **scopeSummary** — human-readable description of what was covered ("Previous calendar lookup covered today and returned 3 events")
- **machineReadableScope** — structured JSON for precise comparison (e.g., `{"timeframe": "today", "returned_count": 3, "absolute_date": "2026-04-07"}`)

### Conversation window

The last 4 messages provide conversational context without overwhelming the small model.

### Session summary

When available, a compact rolling session summary is injected so the router can preserve longer context without loading the full conversation history.

### Reference time

An explicit time reference with timezone, including resolved "Today means..." and "Tomorrow means..." labels, so the model can correctly interpret relative time expressions.

## Debug tracing

When `debug` is enabled in the config, every classifier attempt is recorded with:

- **stage** — `classifier`
- **strict** — whether this was a retry attempt
- **status** — outcome (`accepted`, `empty_response`, `invalid_json`, `invalid_selection`, `model_error`)
- **output** — the sanitized raw model output

All attempts are accumulated and serialized as a JSON array attached to the final routing decision. This trace is printed to the server log and gives full visibility into how the router arrived at its decision.

## Design principles

The Intent Router follows the project's core guidelines:

- **No keyword matching** — routing decisions are made by the model, not by scanning for trigger words. If routing needs improvement, the fix is to improve prompts, tool schemas, and context rather than adding hardcoded patterns.
- **Narrow task** — the model returns one field. It does not justify the choice with reason codes, and it does not fill tool arguments.
- **Local-first** — all classification happens on-device via `apfel`. No network calls are made for routing.
- **Graceful degradation** — if the model fails to produce valid output across both attempts, the router asks for clarification rather than guessing.

For calendar creation specifically, the router only chooses the tool. The later tool-call stage is still responsible for asking a short clarification question when timing or duration details are missing.

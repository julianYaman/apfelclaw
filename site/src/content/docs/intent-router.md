---
title: Intent Router
description: How apfelclaw decides when to use a tool — the 3-stage, model-driven routing flow.
order: 6
---

The Intent Router is the decision-making core of apfelclaw. On every user message, it determines whether to invoke a tool or answer directly. Rather than relying on keyword matching or hardcoded trigger phrases, it uses sequential model calls to classify intent.

## Overview

The router runs up to **three stages**, each a lightweight classification call to the on-device model. If any stage produces a definitive tool selection, routing stops immediately. If all stages pass without selecting a tool, the fallback is to answer directly.

```
User message
    │
    ▼
┌─────────────────────┐
│  Stage 1: Classify   │──── tool selected? ──▶ Done (use tool)
└─────────────────────┘
    │ no
    ▼
┌─────────────────────┐
│  Stage 2: Follow-up  │──── reuse tool? ─────▶ Done (use tool)
│  reuse check         │
└─────────────────────┘
    │ no
    ▼
┌─────────────────────┐
│  Stage 3: Direct     │──── override? ───────▶ Done (use tool)
│  answer verification │
└─────────────────────┘
    │ no
    ▼
  Answer directly
```

## Stage 1: Classifier

The first stage asks the model to choose between `use_tool` (with a specific tool name) or `answer_directly`.

The model receives:

- A system prompt listing all registered tools with their **domain**, **purpose**, **use_when**, **avoid_when**, **examples**, and **returns**
- The current **reference date and timezone** with explicit labels ("Today means 2026-04-07", "Tomorrow means 2026-04-08")
- A summary of the **last tool call** (if any), including its scope snapshot
- The **last 4 messages** of conversation context
- The latest **user message**

The model returns a JSON object:

```json
{
  "action": "use_tool",
  "toolName": "list_calendar_events",
  "reasonCode": "fresh_personal_data"
}
```

If the model selects a valid tool, routing is complete. If it selects `answer_directly`, the router proceeds to Stage 2.

## Stage 2: Follow-up reuse

This stage only runs when two conditions are met:

1. Stage 1 did **not** select a tool
2. There is a recent approved tool call whose module has **`supportsFollowUpReuse`** enabled

Currently, `list_calendar_events` (calendar domain) and `list_recent_mail` (mail domain) support follow-up reuse. File and terminal tools do not.

The model is asked: "Is the user continuing the previous tool-backed request in the same domain?" It receives the prior tool's scope snapshot so it can compare what was previously covered with what the user is now asking.

For example, if the user previously asked "What meetings do I have today?" and now asks "What about tomorrow?", the model can recognize this as a follow-up in the calendar domain and reuse the calendar tool.

The model returns:

```json
{
  "reuseLastTool": true,
  "reasonCode": "same_domain_follow_up"
}
```

If `reuseLastTool` is true, the routing decision becomes `use_tool` with the previous tool name.

## Stage 3: Direct answer verification

This stage runs when Stage 1 chose `answer_directly` and Stage 2 did not recover a tool. It acts as a safety net for the small on-device model, which may sometimes skip a tool for requests about personal or local data.

The model is re-presented with the tool list and asked whether a tool should **override** the direct answer decision. This catches cases where the user asks something like "What's on my calendar?" and the model incorrectly decides it can answer without a tool.

Unlike the classifier and follow-up stages, this verification step looks only at the latest user message. It intentionally ignores prior conversation and previous tool calls so that acknowledgements like "Thanks" or "Thank you." do not get pulled back into a calendar or mail tool route just because the earlier context was tool-backed.

```json
{
  "toolName": "list_calendar_events",
  "reasonCode": "fresh_personal_data"
}
```

If a tool name is returned, the decision is overridden to `use_tool`. If null, `answer_directly` stands.

## Reason codes

Every routing decision includes a reason code explaining why the decision was made:

| Code | Meaning |
|---|---|
| `fresh_personal_data` | User wants live local/personal data (calendar, mail, files, system info) |
| `same_domain_follow_up` | User is continuing a conversation in the same tool domain with changed scope |
| `prior_result_insufficient` | The previous tool result didn't cover what the user is now asking |
| `direct_answer_ok` | Pure chat, greeting, or stable knowledge — no tool needed |
| `other` | Catch-all fallback |

Reason codes are validated for consistency: `direct_answer_ok` is not allowed when the action is `use_tool`, and only `direct_answer_ok` or `other` are valid when answering directly.

## Retry mechanism

Each stage tries **twice**:

1. **Normal attempt** — standard prompt
2. **Strict retry** — if the first attempt produces unparseable JSON or fails validation, the prompt is augmented with a notice: "Previous output was invalid. Retry and return exactly one JSON object matching the schema."

This means the router makes up to 6 model calls in the worst case (2 per stage). In practice, Stage 1 resolves most messages on the first attempt.

If both attempts in a stage fail, the stage returns no result and control falls through to the next stage (or the final `answer_directly` fallback).

## Context assembly

Each stage builds its prompt from several sources:

### Tool registry

The router reads from each tool module's routing metadata:

- **domain** — semantic grouping (e.g., `files`, `calendar`, `mail`, `terminal`)
- **purpose** — what the tool does
- **use_when / avoid_when** — guidance for the model
- **examples** — natural-language trigger phrases
- **returns** — what the tool's output contains

### Last tool call summary

When a tool was used in a recent turn, the router injects a `ToolResultSnapshot`:

- **scopeSummary** — human-readable description of what was covered ("Previous calendar lookup covered today and returned 3 events")
- **machineReadableScope** — structured JSON for precise comparison (e.g., `{"timeframe": "today", "returned_count": 3, "absolute_date": "2026-04-07"}`)

### Conversation window

The last 4 messages provide conversational context without overwhelming the small model.

### Reference time

An explicit time reference with timezone, including resolved "Today means..." and "Tomorrow means..." labels, so the model can correctly interpret relative time expressions.

## Debug tracing

When `debug` is enabled in the config, every model call across all stages is recorded as a debug attempt with:

- **stage** — which stage (`classifier`, `follow_up`, `direct_answer_check`)
- **strict** — whether this was a retry attempt
- **status** — outcome (`accepted`, `empty_response`, `invalid_json`, `invalid_selection`)
- **output** — the sanitized raw model output

All attempts are accumulated and serialized as a JSON array attached to the final routing decision. This trace is printed to the server log and gives full visibility into how the router arrived at its decision.

## Design principles

The Intent Router follows the project's core guidelines:

- **No keyword matching** — routing decisions are made by the model, not by scanning for trigger words. If routing needs improvement, the fix is to improve prompts, tool schemas, and context rather than adding hardcoded patterns.
- **Local-first** — all classification happens on-device via `apfel`. No network calls are made for routing.
- **Graceful degradation** — if the model fails to produce valid output across all retries and stages, the router falls back to `answer_directly` rather than erroring.

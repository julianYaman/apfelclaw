# AGENTS

- Do not implement tool routing or follow-up detection with explicit word-matching lists, keyword tables, or phrase-pattern heuristics.
- Let the model decide when a tool should run, using structured prompts and recent conversation context.
- If extra routing reliability is needed, improve the model-facing context or schema rather than adding hardcoded trigger words.

## Apple Foundation Models notes

- Treat Apple’s on-device Foundation Models model as a small general-purpose model: keep tasks narrow, avoid depending on strong code/math/world-knowledge performance, and use tools for fresh or exact data.
- Keep tool definitions explicit and semantically rich. Apple’s guidance around tool calling aligns with this project rule: improve instructions, tool names, descriptions, and argument schemas instead of adding keyword-trigger routing.
- Handle model availability as a first-class product concern. The backend and clients should expect states like unsupported device or Apple Intelligence disabled and offer a clean fallback path.
- Favor deterministic settings and regression fixtures for development. Preserve representative prompt/tool transcripts and use stable generation settings when testing routing or UI behavior so model/framework updates are easier to catch.
- Preserve the local-first privacy model from the README. Default to on-device execution and only reach for network-backed tools when the task actually requires external knowledge or side effects.

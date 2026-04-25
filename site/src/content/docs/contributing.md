---
title: Contributing
description: Contribution guidelines, development environment, testing, and pull request process.
order: 7
---

Thanks for contributing to apfelclaw. The project is still compact, so the goal is to keep the contribution path simple and explicit.

## Before you start

- Read the [Getting Started](/docs/getting-started) guide for architecture and local setup
- Check existing [issues](https://github.com/anomalyco/apfelclaw/issues) before starting larger work
- Prefer opening a short issue or discussion before large changes to architecture, UX, or tool behavior

## Development environment

**Required:**

- macOS 26 Tahoe or newer
- Swift 6.3+
- Bun 1.0+
- `apfel` installed and available on `PATH`

Install dependencies and run the main development flows from the repository root:

```bash
npm install
npm run test:server
./apfelclaw
npm run dev:tui
```

## Project structure

| Path | Description |
|---|---|
| `packages/apfelclaw-server` | Backend runtime, local API, persistence, and tool execution |
| `apps/tui` | Terminal UI client |

## Contribution guidelines

- **Keep the local-first privacy model intact.** Do not add network-backed behavior unless the task explicitly requires it.
- **Avoid keyword tables or hardcoded trigger phrases** for routing tool calls. Improve prompts, schemas, and context instead.
- **Prefer small, reviewable pull requests** with a clear user-visible outcome.
- **Update documentation** when behavior, setup, or contributor workflow changes.
- **Add or update tests** for backend changes when the behavior is covered by automated tests.

## Testing

### Backend tests

```bash
npm run test:server
```

Or invoke SwiftPM directly:

```bash
swift test --package-path packages/apfelclaw-server
```

### TUI

The TUI does not currently have a dedicated automated test target. If your change affects the TUI, include manual verification notes in the pull request.

## Pull requests

When opening a pull request:

- **Explain the problem** being solved
- **Keep the scope focused** — one concern per PR
- **Describe how you verified** the change
- **Call out follow-up work** or known limitations

If your change affects prompts, tool schemas, or routing behavior, include enough context in the PR description for reviewers to understand the before and after behavior.

## Useful references

- [API Reference](/docs/api) — endpoint details and config options
- [Connections](/docs/connections) — remote control providers and setup
- [Tools](/docs/tools) — tool catalog and parameter schemas
- [Intent Router](/docs/intent-router) — how routing decisions are made

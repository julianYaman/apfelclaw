# Contributing to apfelclaw

Thanks for contributing. This project is still compact, so the goal is to keep the contribution path simple and explicit.

## Before you start

- Read [`README.md`](README.md) for the current architecture and local setup.
- Check existing issues before starting larger work.
- Prefer opening a short issue or discussion before large changes to architecture, UX, or tool behavior.

## Development environment

Required:

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

- `packages/apfelclaw-server`: backend runtime, local API, persistence, and tool execution
- `apps/tui`: terminal UI client

## Contribution guidelines

- Keep the local-first privacy model intact. Do not add network-backed behavior unless the task explicitly requires it.
- Avoid keyword tables or hardcoded trigger phrases for routing tool calls. Improve prompts, schemas, and context instead.
- Prefer small, reviewable pull requests with a clear user-visible outcome.
- Update documentation when behavior, setup, or contributor workflow changes.
- Add or update tests for backend changes when the behavior is covered by automated tests.

## Testing

Backend tests:

```bash
npm run test:server
```

Direct SwiftPM invocation:

```bash
swift test --package-path packages/apfelclaw-server
```

The TUI currently does not have a dedicated automated test target in this repository. If your change affects the TUI, include manual verification notes in the pull request.

## Pull requests

When opening a pull request:

- explain the problem being solved
- keep the scope focused
- describe how you verified the change
- call out follow-up work or known limitations

If your change affects prompts, tool schemas, or routing behavior, include enough context in the PR description for reviewers to understand the before and after behavior.

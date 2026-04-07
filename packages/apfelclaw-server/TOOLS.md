# Tools

`apfelclaw` loads its runtime tool catalog from `Sources/ApfelClawCore/Resources/tools.json`.

The model does not read this file directly. The app loads the JSON manifest, converts it into the OpenAI-compatible `tools` payload, sends that payload to `apfel`, and then maps approved tool calls back to local Swift executors.

Current tools:

## `find_files`

- Purpose: Find files on this Mac using Spotlight-backed search.
- Use when: The user needs to locate files by name or search phrase.
- Avoid when: The user already has an exact absolute path.
- Read-only: yes
- Confirmation required: yes
- Parameters:
  - `query` string, required
  - `limit` integer, optional

## `get_file_info`

- Purpose: Get metadata for an exact file or directory path.
- Use when: The user already provided the exact path.
- Avoid when: The user needs to search for the path first.
- Read-only: yes
- Confirmation required: yes
- Parameters:
  - `path` string, required

## `list_calendar_events`

- Purpose: Read upcoming events from the user's calendars.
- Use when: The user asks about meetings or schedule items for today, tomorrow, or next week.
- Avoid when: The user wants to create or edit events.
- Read-only: yes
- Confirmation required: yes
- Parameters:
  - `timeframe` string, required
  - `limit` integer, optional

## `run_safe_command`

- Purpose: Run one read-only native macOS terminal command from the safe allowlist.
- Use when: A single allowlisted read-only shell command directly answers the question.
- Avoid when: The task needs shell syntax, write access, or unsupported commands.
- Read-only: yes
- Confirmation required: yes
- Parameters:
  - `command` string, required
  - `arguments` array, optional

Safe command allowlist:

- `pwd`
- `ls`
- `whoami`
- `date`
- `mdfind`
- `mdls`
- `stat`
- `find`
- `ps`
- `lsof`

## `list_recent_mail`

- Purpose: Read recent messages from Apple Mail inbox.
- Use when: The user asks for latest or recent emails.
- Avoid when: The user asks for specific mail search, message bodies, or mail actions.
- Read-only: yes
- Confirmation required: yes
- Parameters:
  - `limit` integer, optional

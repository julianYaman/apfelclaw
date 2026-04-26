# Tools

`apfelclaw` loads its runtime tool catalog from `Sources/ApfelClawCore/Resources/tools.json`.

The model does not read this file directly. The app loads the JSON manifest, converts it into the OpenAI-compatible `tools` payload, sends that payload to `apfel`, and then maps approved tool calls back to local Swift executors.

Current tools:

## `find_files`

- Purpose: Find files on this Mac using Spotlight-backed search.
- Use when: The user needs to locate files by name or search phrase.
- Avoid when: The user already has an exact absolute path.
- Read-only: yes
- Confirmation required: no
- Parameters:
  - `query` string, required
  - `limit` integer, optional

## `get_file_info`

- Purpose: Get metadata for one exact file or directory path, including paths that start with `~/`.
- Use when: The user already provided one exact path.
- Avoid when: The user needs to search for the path first.
- Read-only: yes
- Confirmation required: no
- Parameters:
  - `path` string, required

## `list_calendar_events`

- Purpose: Read upcoming events from the user's calendars for a requested time range.
- Use when: The user asks about meetings or schedule items for a natural-language time range.
- Avoid when: The user wants to create, edit, or delete events.
- Read-only: yes
- Confirmation required: no
- Parameters:
  - `timeframe` string, required
  - `limit` integer, optional

## `add_calendar_event`

- Purpose: Create one calendar event in the user's calendars.
- Use when: The user asks to add, create, or schedule a calendar event, meeting, or appointment.
- Avoid when: The user wants to list events, edit or delete an existing event, or create a recurring event.
- Read-only: no
- Confirmation required: yes
- Parameters:
  - `title` string, required
  - `starts_at` string, required
  - `ends_at` string, optional
  - `duration_minutes` integer, optional
  - `location` string, optional
  - `notes` string, optional

## `get_mac_status`

- Purpose: Read current status information from this Mac, such as battery, power source, thermal state, memory, storage, and uptime.
- Use when: The user asks about this Mac's current health, battery, power, memory, disk space, temperature state, or uptime.
- Avoid when: The user asks about files, calendar, mail, or anything that requires a shell command rather than direct system status APIs.
- Read-only: yes
- Confirmation required: no
- Parameters:
  - `sections` array, optional, allowed values: `battery`, `power`, `thermal`, `memory`, `storage`, `uptime`

## `run_safe_command`

- Purpose: Run one read-only native macOS terminal command from the safe allowlist.
- Use when: A single allowlisted read-only shell command directly answers the question.
- Avoid when: The task needs shell syntax, write access, or unsupported commands.
- Read-only: yes
- Confirmation required: no
- Parameters:
  - `command` string, required
  - `arguments` array, optional, subject to command-specific safe argument rules

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
- Confirmation required: no
- Parameters:
  - `limit` integer, optional

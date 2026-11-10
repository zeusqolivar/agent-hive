# Spike S2: status line usage data from desktop sessions

Date: 2026-11-10. Claude Code CLI 2.1.283 at the start of the spike; its auto-updater installed 2.1.322
while the test session ran. The desktop app bundles its own CLI (2.1.321). Done in a throwaway folder with a
project-level `.claude/settings.json`; the user-level `~/.claude/settings.json` was not changed.

## Result

- **Terminal sessions run status line commands.** An interactive session in the test folder ran the
  project's `statusLine` command three times during one prompt and quit, each time with a JSON object on
  stdin.
- **No `rate_limits` was received in the test**, because the standalone CLI's login had expired on the test Mac
  ("Login expired · Please run /login"), so no request reached the API. The CLI documents that `rate_limits`
  is present only for subscribers and only while the API reports it, so a signed-out or failed session sends
  none.
- **Print mode (`claude -p`) does not run the status line command.** The output file did not grow.
- **Desktop-app sessions very likely do not run status line commands** (confidence: high, not observed
  directly). Their `claude` processes run with `--input-format stream-json --output-format stream-json`,
  have no terminal (`ps` shows `??` as their TTY), and the desktop app draws its own interface. The status
  line is part of the terminal interface, and print mode, the closest documented mode, doesn't run it. The
  tester's user-level settings had no `statusLine` set, so there was nothing to observe on real sessions
  either way, and adding one was out of bounds for the spike.

So a meter built on the status line updates only while a terminal session is used. The Usage view must say
where the figures came from and how old they are.

## JSON received on stdin (terminal session, signed out)

Top-level and nested keys seen: `context_window.{context_window_size, current_usage, remaining_percentage,
total_input_tokens, total_output_tokens, used_percentage}`, `cost.{total_api_duration_ms, total_cost_usd,
total_duration_ms, total_lines_added, total_lines_removed}`, `cwd`, `exceeds_200k_tokens`, `fast_mode`,
`model.{display_name, id}`, `output_style.name`, `session_id`, `thinking.enabled`, `transcript_path`,
`version`, `workspace.{added_dirs, current_dir, project_dir}`. No `rate_limits` key.

## `rate_limits` keys

Not seen in a live payload (see above). The CLI's own status line documentation, embedded in the 2.1.322
binary, gives this shape:

```
"rate_limits": {
  "five_hour":  { "used_percentage": number, "resets_at": number },
  "seven_day":  { "used_percentage": number, "resets_at": number },
  "spend_limit": { "used_percentage": number, "resets_at": number,
                   "used_usd": number, "limit_usd": number, "period": "daily" | "weekly" | "monthly" }
}
```

- `used_percentage` is 0 to 100; `resets_at` is Unix epoch seconds.
- Each window is optional: present only while the API reports it and its `resets_at` hasn't passed.
- `spend_limit` appears only behind a Claude gateway with a spend limit.
- The changelog entry that introduced the field: "Added `rate_limits` field to statusline scripts for
  displaying Claude.ai rate limit usage (5-hour and 7-day windows with `used_percentage` and `resets_at`)".

## How it was tested

1. Temp folder with `.claude/settings.json`:
   `{"statusLine": {"type": "command", "command": "cat >> <folder>/statusline.jsonl; echo >> <folder>/statusline.jsonl; echo s2-status"}}`.
2. An interactive `claude --model haiku` in a pseudo-terminal (a small Python `pty` driver standing in for
   `script -q /dev/null`, because the session had to be driven by keystrokes): trusted the folder, sent one
   prompt, `/exit`. Three JSON objects arrived.
3. `claude -p "Reply with the word ready" --model haiku` in the same folder: no new JSON.
4. Read-only: desktop session arguments and TTY from `ps`, the CLI's help and embedded docs, and
   `~/.claude/cache/changelog.md`.

## Notes for phase 3

- Projects can set their own `statusLine`; a project setting replaces the user's. The installer in phase 3
  works on the user-level setting, so a project with its own status line won't feed the meter.
- Project-level status line commands run only after the folder is trusted.
- Re-check with a signed-in CLI and record a real `rate_limits` payload before building the meter.

## Cleanup

The temp folder, its transcripts under `~/.claude/projects/` and the matching `~/.claude/session-env/`
folder were deleted. The CLI records trusted folders in `~/.claude.json`; that file was left untouched.

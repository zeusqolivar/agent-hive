# Spike S1: replying to a session from outside Claude

Date: 2026-11-10. Claude Code CLI 2.1.283 (`~/.local/bin/claude`); the desktop app bundles its own CLI
(2.1.321). Everything was tried on a throwaway folder and sessions made for the spike, then deleted.

## Result

Only one case is safe: **a session with no running process**, resumed with `claude --resume <id> -p`.
Everything else either forks the conversation or has no input channel an outside app can use.

| Case | Safe to send | Evidence | Command |
|---|---|---|---|
| Not running (no live pid, no process with `--resume <id>`) | **Yes**, if the CLI is signed in | The reply is appended to the same `<id>.jsonl`, the session id stays the same, and each new turn's first line has the previous turn's last line as its `parentUuid`, so the chain stays linear. A later `--resume` continues from the reply. | `cd <session cwd> && claude --resume <id> -p --output-format json`, with the text on stdin, no `CLAUDE*` variables in the environment and no permission flags (see "Command used by the app") |
| Running in a terminal | No | Two `--resume <id> -p` processes running at the same time (held open with a 25 s `UserPromptSubmit` hook in the test folder's project settings) both wrote to the same file under the same id, and both turns hung off the same parent line: the conversation tree forked inside the file. The next `--resume` followed only the newest branch, so the other turn dropped out of the conversation. The CLI's own help says `--resume <id> --bg` "starts a copy" when the session is already running. | none |
| Running in the desktop app | No | `ps` shows desktop sessions as `claude --input-format stream-json --output-format stream-json --permission-prompt-tool=stdio --resume=<id> ...`, a child of the Claude app. Input arrives over the app's private stdin pipe; no documented outside channel exists. Writing through `--resume -p` would fork exactly as in the terminal case. | none |
| Waiting on a permission prompt | No | Desktop sessions answer prompts over the same stdio pipe (`--permission-prompt-tool=stdio`); terminal sessions answer in the TUI. Hooks (`PermissionRequest`) can decide prompts, but only when configured before the session starts, and that changes the user's settings. No documented way answers a prompt that is already pending. | none |
| Waiting on a question (`AskUserQuestion` or `ExitPlanMode` pending) | No | The session is running and waiting on its own input channel; same as the running cases. | none |

A finished turn that ended with a `wrap_up` question, where the process has since stopped, is the
"not running" case and is safe.

## How the cases were tested

1. `claude -p "Reply with the word ready" --model haiku` in a new temp folder created one session file
   under `~/.claude/projects/<folder>/`.
2. `claude --resume <id> -p "Reply with the word second"` with nothing running: same file grew from 23 to 33
   lines, same `session_id` in the JSON output, linear `parentUuid` chain.
3. A project-level `UserPromptSubmit` hook (`sleep 25`) in the temp folder kept a first
   `--resume <id> -p "Run sleep 40 then reply done"` alive; a second `--resume <id> -p` started 4 seconds
   later. Every line of the file was still valid JSON (51 of 51), but one line had two children: a fork.
   A fourth `--resume` continued from the second writer's branch only.
4. `ps` (read-only) for existing desktop sessions, arguments only. Nothing was sent to them.
5. `claude --help` and `~/.claude/cache/changelog.md` for any documented input or permission channel.

## Problems found along the way

- **The CLI's own sign-in can differ from the desktop app's.** On this Mac every spike run answered
  `Failed to authenticate: OAuth session expired and could not be refreshed`: the desktop app signs its
  own bundled CLI in, and the standalone CLI's login had expired. The app would run the standalone CLI, so
  on such a Mac every reply fails.
- **A failed reply still writes to the session.** The failed run appended the user's message and a
  synthetic assistant line with the error text to the transcript. A reply sent while signed out pollutes
  the conversation the user later continues.
- Because of the sign-in problem the model never answered, so "the user sees the reply in Claude
  afterwards" is shown at the transcript level (same file, linear chain) but was not seen in the desktop
  app's own window. The desktop app resumes sessions with `--resume=<id>` from the same transcript folder,
  so it should load the reply, but this is unverified.

## What the app should do

- Offer the reply box only when the session has no live process: its pid is not alive or no longer runs
  `claude`, and no running process has `--resume <id>` or `--resume=<id>` in its arguments.
- Run the command above with `/dev/null` as stdin, the user's own permission settings (anything that needs
  a prompt is denied in print mode), no `--dangerously-skip-permissions`, and `CLAUDE*` variables removed.
- Tell the user, before the first reply, that the standalone `claude` CLI must be signed in, and show the
  CLI's error text when a reply fails.
- For every other case, show why and keep **Open in Claude**.

## Command used by the app

The spike passed the text as an argument. The app passes it on stdin instead
(`claude --resume <id> -p --output-format json`, text written to stdin, then closed), so text that starts
with `-` can never be read as a flag such as `--dangerously-skip-permissions`. Checked on a throwaway session
on 2026-11-10: a reply of `--model opus Reply with the word second` was stored as the user's message in the
same transcript, under the same session id.

## Cleanup

The temp folder, its `~/.claude/projects/<folder>/` transcripts and the matching `~/.claude/session-env/<id>/`
folders were deleted. The CLI also records the folder in its own project list in `~/.claude.json`; that
user-level file was left untouched.

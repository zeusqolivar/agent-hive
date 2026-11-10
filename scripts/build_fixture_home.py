#!/usr/bin/env python3
"""Write the synthetic fixture home used by the contract tests.

Usage: python3 scripts/build_fixture_home.py [Tests/HiveCoreTests/Fixtures/home]

Everything here is made up. `__HOME__` stands for the fixture home's real location; the contract
script and the Swift tests copy the folder somewhere temporary and replace it there. All times are
fixed relative to NOW (2026-11-10 12:00:00 UTC), which both sides use as the current time.
"""
import datetime as dt
import json
import os
import plistlib
import shutil
import sqlite3
import sys

NOW = 1794312000
HOME = "__HOME__"
DEMO = HOME + "/Projects/demo"
OTHER = HOME + "/Projects/other"
PROJECT_DIR = ".claude/projects/-fixture-Projects-demo"


def iso(t, ms=123):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + f".{ms:03d}Z"


class Log:
    """Builds one transcript, one JSON object per line, in the shape Claude Code writes."""

    def __init__(self, sid, start, cwd=DEMO, branch="feat/parser"):
        self.sid, self.t, self.cwd, self.branch = sid, start, cwd, branch
        self.lines, self.n, self.parent = [], 0, None

    def _base(self, kind, step=20):
        self.t += step
        self.n += 1
        uid = f"{self.sid}-u{self.n:03d}"
        d = {"parentUuid": self.parent, "isSidechain": False, "userType": "external", "cwd": self.cwd,
             "sessionId": self.sid, "version": "2.1.300", "gitBranch": self.branch, "type": kind,
             "uuid": uid, "timestamp": iso(self.t)}
        self.parent = uid
        return d

    def raw(self, obj):
        self.lines.append(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))

    def user(self, content, **extra):
        d = self._base("user")
        d["message"] = {"role": "user", "content": content}
        d.update(extra)
        self.raw(d)

    def result(self, tool_id, content, error=False):
        part = {"type": "tool_result", "tool_use_id": tool_id, "content": content}
        if error:
            part["is_error"] = True
        self.user([part])

    def assistant(self, parts, msg_id, model="claude-opus-5-5", stop=None, output=20, usage=True, **extra):
        d = self._base("assistant")
        msg = {"id": msg_id, "type": "message", "role": "assistant", "model": model, "content": parts,
               "stop_reason": stop}
        if usage:
            msg["usage"] = {"input_tokens": 12, "cache_read_input_tokens": 4000,
                            "cache_creation_input_tokens": 300, "output_tokens": output}
        d["message"] = msg
        d["effort"] = "high"
        d.update(extra)
        self.raw(d)

    def write(self, path, tail=""):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write("\n".join(self.lines) + "\n" + tail)


def text(t):
    return {"type": "text", "text": t}


def tool(tid, name, inp):
    return {"type": "tool_use", "id": tid, "name": name, "input": inp}


def main_session(root):
    """A working session: every kind of event, two pending calls, a cut-off last line."""
    log = Log("sess-main-0001", NOW - 3600)
    log.raw({"type": "mode", "mode": "acceptEdits", "sessionId": log.sid})
    log.user("<local-command-caveat>Caveat: ignore</local-command-caveat>", isMeta=True)
    log.user("<system-reminder>Be careful.</system-reminder>Please fix the parser in **src/parse.swift**. "
             "<pasted_content>stack trace here</pasted_content>")
    log.assistant([{"type": "thinking", "thinking": "Let me look at the parser first.", "signature": "c2ln"},
                   text("I'll start by reading the parser.")], "msg_m01", output=40)
    log.assistant([{"type": "thinking", "thinking": "", "signature": "c2lnMg=="},
                   tool("toolu_plan1", "mcp__ccd_turn__update_plan", {"items": [
                       {"content": "Read the parser", "status": "in_progress"},
                       {"content": "Fix the failing tests", "status": "pending"},
                       {"content": "Run the full suite", "status": "pending"}], "scope": "first_task"})],
                  "msg_m02", output=60)
    log.assistant([tool("toolu_r1", "Read", {"file_path": DEMO + "/src/parse.swift"})], "msg_m03")
    log.result("toolu_r1", "1\tstruct Parser {}\n2\t")
    log.assistant([tool("toolu_b1", "Bash", {"command": "swift test 2>&1 | tail -20",
                                             "description": "Run the tests"})], "msg_m04")
    log.result("toolu_b1", [text("error: 2 tests failed\nParserTests.swift:10: failure")], error=True)
    log.assistant([tool("toolu_plan2", "mcp__ccd_turn__update_plan", {"advance": True})], "msg_m05")
    log.assistant([tool("toolu_e1", "Edit", {"file_path": DEMO + "/src/parse.swift",
                                             "old_string": "struct Parser {}",
                                             "new_string": "struct Parser {\n    var input: String\n}"})],
                  "msg_m06")
    log.result("toolu_e1", "The file has been updated successfully.")
    log.user("<task-notification>\n<task-id>bg1</task-id>\n<status>completed</status>\n</task-notification>")
    log.assistant([tool("toolu_plan3", "mcp__ccd_turn__update_plan", {"done": [2], "start": 3})], "msg_m07")
    log.assistant([tool("toolu_ts", "ToolSearch", {"query": "select:Foo"}),
                   tool("toolu_ch", "mcp__ccd_session__mark_chapter", {"title": "Fixing"})], "msg_m08")
    log.assistant([tool("toolu_w1", "WebSearch", {"query": "swift regex lookbehind"})], "msg_m09")
    log.result("toolu_w1", "Result 1\nResult 2")
    log.assistant([tool("toolu_m1", "mcp__plugin_figma_figma__get_screenshot", {"nodeId": "1:2"})], "msg_m10")
    log.result("toolu_m1", [{"type": "image", "source": {"type": "base64", "data": "AAAA"}}])
    log.assistant([text("The tests fail because the input is never stored.")], "msg_m11", output=30)
    log.raw({"type": "api-request", "sessionId": log.sid, "timestamp": iso(log.t)})
    log.assistant([tool("toolu_a1", "Agent", {"description": "Find the parser callers",
                                              "subagent_type": "Explore", "prompt": "List every caller."})],
                  "msg_m12")
    log.assistant([tool("toolu_b2", "Bash", {"command": "swift build 2>&1 | tail -5",
                                             "description": "Build the package"})], "msg_m13")
    log.write(os.path.join(root, PROJECT_DIR, "sess-main-0001.jsonl"),
              tail='{"type":"assistant","message":{"content":[{"type":"text","te')

    sub = os.path.join(root, PROJECT_DIR, "sess-main-0001", "subagents")
    os.makedirs(sub, exist_ok=True)
    with open(os.path.join(sub, "agent-a1b2c3d4.meta.json"), "w") as fh:
        json.dump({"agentType": "Explore", "description": "Find the parser callers"}, fh)
    agent = Log("sess-main-0001", NOW - 900)
    agent.user("List every caller of Parser.")
    agent.assistant([text("Searching for callers.")], "msg_s01", model="claude-haiku-5")
    agent.assistant([tool("toolu_s1", "Grep", {"pattern": "Parser\\("})], "msg_s02", model="claude-haiku-5")
    agent.result("toolu_s1", "src/main.swift:3")
    agent.assistant([tool("toolu_s2", "Read", {"file_path": DEMO + "/src/main.swift"})], "msg_s03",
                    model="claude-haiku-5")
    agent.write(os.path.join(sub, "agent-a1b2c3d4.jsonl"))

    with open(os.path.join(sub, "agent-e5f6a7b8.meta.json"), "w") as fh:
        json.dump({"agentType": "general-purpose", "description": "Write parser tests", "finished": True}, fh)
    done = Log("sess-main-0001", NOW - 2400)
    done.user("Write tests for the parser.")
    done.assistant([tool("toolu_s3", "Write", {"file_path": DEMO + "/Tests/ParserTests.swift",
                                               "content": "import Testing\n"})], "msg_s04", model="claude-haiku-5")
    done.result("toolu_s3", "File created.")
    done.assistant([text("Wrote three tests. They cover empty input.")], "msg_s05", model="claude-haiku-5",
                   stop="end_turn")
    done.write(os.path.join(sub, "agent-e5f6a7b8.jsonl"))
    # A meta file whose log is missing is skipped.
    with open(os.path.join(sub, "agent-deadbeef.meta.json"), "w") as fh:
        json.dump({"agentType": "Explore", "description": "No log"}, fh)


def asked_session(root):
    """Finished a turn with a wrap_up that asks a question."""
    log = Log("sess-asked-0002", NOW - 7200, branch="main")
    log.raw({"type": "pr-link", "prUrl": "https://github.com/example/demo/pull/7", "prNumber": 7,
             "prRepository": "example/demo", "sessionId": log.sid})
    log.raw({"type": "pr-link", "prUrl": "http://insecure.example/pull/8", "prNumber": 8})
    log.user("Make the release build work.")
    log.assistant([text("Building the release now.")], "msg_a01")
    log.assistant([tool("toolu_ab1", "Bash", {"command": "swift build -c release"})], "msg_a02")
    log.result("toolu_ab1", "Build complete!")
    log.assistant([text("The release build works now.")], "msg_a03")
    log.assistant([tool("toolu_wu1", "mcp__ccd_turn__wrap_up", {
        "recap": "Fixed the release build. It now compiles in 40 seconds.",
        "ask": "Should I push the branch?", "actions": [{"label": "Push"}]})], "msg_a04", stop="end_turn")
    log.write(os.path.join(root, PROJECT_DIR, "sess-asked-0002.jsonl"))


def done_session(root):
    """A named session that finished its plan and wrapped up without a question."""
    log = Log("sess-done-0003", NOW - 10800, branch="HEAD")
    log.raw({"type": "custom-title", "customTitle": "Release notes", "sessionId": log.sid})
    log.raw({"type": "last-prompt", "lastPrompt": "Write the release notes", "sessionId": log.sid})
    log.user("Write the release notes for 2.0.")
    log.assistant([tool("toolu_td", "TodoWrite", {"todos": [
        {"content": "Collect changes", "status": "completed"},
        {"content": "Write notes", "status": "in_progress"}]})], "msg_d01")
    log.assistant([{"type": "thinking", "thinking": "", "signature": "eA=="},
                   text("Here are the notes.\n\n**Added** a parser.")], "msg_d02")
    log.assistant([tool("toolu_wu2", "mcp__ccd_turn__wrap_up", {
        "recap": "Shipped the release notes for version 2.0. Next is the changelog."})], "msg_d03",
                  stop="end_turn")
    log.write(os.path.join(root, PROJECT_DIR, "sess-done-0003.jsonl"))


def big_session(root):
    """A 3 MB tool result near the end, so the 2 MB tail finds few events and the reader widens to 16 MB."""
    log = Log("sess-big-0004", NOW - 20000, cwd=OTHER, branch="main")
    log.user("Summarise the logs.")
    for i in range(25):
        log.assistant([text(f"Step {i + 1}: looked at log file number {i + 1}.")], f"msg_g{i:02d}", output=5)
    log.assistant([tool("toolu_g1", "Bash", {"command": "cat huge.log"})], "msg_gbig")
    log.result("toolu_g1", "x" * 3_000_000)
    for i in range(3):
        log.assistant([text(f"After the big output, note {i + 1}.")], f"msg_h{i:02d}", output=5)
    log.write(os.path.join(root, ".claude/projects/-fixture-Projects-other", "sess-big-0004.jsonl"))


def usage_session(root):
    """Token counting: one response written as three lines, other days, a synthetic line."""
    log = Log("sess-usage-0005", NOW - 3 * 86400, cwd=OTHER, branch="main")
    log.user("Count tokens.")
    log.t = NOW - 2 * 86400 - 3600
    log.assistant([text("Two days ago.")], "msg_u03", output=100)
    log.t = NOW - 10 * 86400
    log.assistant([text("Ten days ago, outside the window.")], "msg_u04", output=999)
    log.t = NOW - 1800
    for out in (10, 25, 40):
        log.assistant([text(f"Block with {out} tokens so far.")], "msg_u01", output=out)
    log.assistant([text("Same output again, no growth.")], "msg_u01", output=40)
    log.assistant([text("A small model reply.")], "msg_u02", model="claude-haiku-5", output=7)
    log.assistant([text("Synthetic.")], "msg_u05", model="<synthetic>", output=50)
    log.write(os.path.join(root, ".claude/projects/-fixture-Projects-other", "sess-usage-0005.jsonl"))


def small_sessions(root):
    q = Log("sess-question-0006", NOW - 5000)
    q.user("Pick a database.")
    q.assistant([tool("toolu_q1", "AskUserQuestion", {"questions": [
        {"question": "Which database should I use?", "options": [{"label": "SQLite"}]}]})], "msg_q01")
    q.write(os.path.join(root, PROJECT_DIR, "sess-question-0006.jsonl"))

    p = Log("sess-plan-0007", NOW - 5200)
    p.user("Plan the migration.")
    p.assistant([tool("toolu_p1", "ExitPlanMode", {"plan": "1. Back up\n2. Migrate"})], "msg_p01")
    p.write(os.path.join(root, PROJECT_DIR, "sess-plan-0007.jsonl"))

    w = Log("sess-planned-0009", NOW - 5400)
    w.user("Tidy the README.")
    w.assistant([tool("toolu_pl1", "mcp__ccd_turn__update_plan", {"items": [
        {"content": "Read the README", "status": "completed"},
        {"content": "Rewrite the install section", "status": "in_progress"}]})], "msg_w01")
    w.assistant([text("Rewriting the install section now.")], "msg_w02")
    w.write(os.path.join(root, PROJECT_DIR, "sess-planned-0009.jsonl"))


def questions_session(root):
    """Finished a turn with questions in plain text and no wrap_up question, a background command still running."""
    log = Log("sess-questions-0011", NOW - 4000, branch="feat/dark-mode")
    log.user("Add dark mode to the settings page.")
    log.assistant([tool("toolu_qe1", "Edit", {"file_path": DEMO + "/src/settings.css",
                                              "old_string": "body {}", "new_string": "body { color: black }"})],
                  "msg_o01")
    log.result("toolu_qe1", "The file has been updated successfully.")
    log.assistant([tool("toolu_qb1", "Bash", {"command": "npm run dev", "description": "Start the dev server",
                                              "run_in_background": True})], "msg_o02")
    log.result("toolu_qb1", "Command running in background with ID: bg2")
    log.assistant([text("Dark mode is in. The toggle sits under **Appearance**, next to the \"Reset?\" button.\n\n"
                        "```css\na:hover { color: red } /* why? */\n```\n\n"
                        "**Left for you to decide:** whether it should follow the system setting by default.\n\n"
                        "Still open:\n\n- the contrast of the disabled buttons\n- Ship it behind a flag?\n\n"
                        "> Should the docs change?\n\n"
                        "Want me to add a screenshot to the README?")], "msg_o03", stop="end_turn")
    log.write(os.path.join(root, PROJECT_DIR, "sess-questions-0011.jsonl"))


AGY = ".gemini/antigravity"
AGY_CWD = "/fixture/Projects/gemini app"   # the database isn't rewritten, so its folders aren't under __HOME__


def agy_iso(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def agy_db_time(t):
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.123456+00:00")


class AgyLog:
    """One Antigravity transcript (brain/<id>/.system_generated/logs/transcript.jsonl), in the shape it writes."""

    def __init__(self, sid, start):
        self.sid, self.t, self.n, self.lines = sid, start, 0, []

    def step(self, kind, step=10, **fields):
        self.t += step
        d = {"step_index": self.n, "source": "CORTEX_STEP_SOURCE_MODEL", "type": kind,
             "status": "CORTEX_STEP_STATUS_DONE", "created_at": agy_iso(self.t)}
        d.update(fields)
        self.n += 1
        self.lines.append(json.dumps(d, ensure_ascii=False))

    def user(self, content):
        self.step("USER_INPUT", source="CORTEX_STEP_SOURCE_USER_EXPLICIT", content=content)

    def planner(self, content=None, tools=(), thinking=None, tokens=(1000, 200, 50)):
        fields = {"input_tokens": tokens[0], "cache_read_tokens": tokens[1], "output_tokens": tokens[2]}
        if content is not None:
            fields["content"] = content
        if thinking is not None:
            fields["thinking"] = thinking
        if tools:
            fields["tool_calls"] = [{"name": n, "args": a} for n, a in tools]
        self.step("PLANNER_RESPONSE", **fields)

    def generic(self, content):
        self.step("GENERIC", content=content)

    def write(self, root, tail=""):
        path = os.path.join(root, AGY, "brain", self.sid, ".system_generated", "logs", "transcript.jsonl")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write("\n".join(self.lines) + "\n" + tail)


def antigravity(root):
    """Google Antigravity: its conversation database, transcripts, background task logs, daemon files and skills."""
    run = AgyLog("agy-run-0001", NOW - 1800)
    run.user("<USER_REQUEST>\nBuild the landing page for the **gemini app**.\n</USER_REQUEST>\n"
             "<ADDITIONAL_METADATA>open files: none</ADDITIONAL_METADATA>")
    run.step("SYSTEM_MESSAGE", source="CORTEX_STEP_SOURCE_SYSTEM", content="Workspace indexed.")
    run.planner("I'll start with the layout.", thinking="Plan the page layout first.",
                tools=[("read_file", {"Path": HOME + "/Projects/gemini app/index.html", "StartLine": "1"})],
                tokens=(1200, 300, 80))
    run.generic("<html></html>")
    run.planner(tools=[("edit_file", {"Path": HOME + "/Projects/gemini app/index.html", "Target": "<html>",
                                      "Replacement": "<html lang=\"en\">"})])
    run.generic("Edited the file.")
    run.planner("None", tools=[("search_web", json.dumps({"query": "hero image ideas"}))])
    run.generic("Result 1\nResult 2")
    run.planner(tools=[("invoke_subagent", {"Role": "Reviewer", "Prompt": "Review the landing page."})])
    run.generic("Looks good.")
    run.planner(tools=[("call_mcp_tool", {"ServerName": "figma", "ToolName": "get_file", "Arguments": "{}"})])
    run.generic("x" * 4500 + "END")
    run.planner(tools=[("manage_task", {"Action": "list", "toolSummary": "List the background tasks"})])
    run.generic("task-7 running")
    run.planner(tools=[("view_file", {"AbsolutePath": HOME + "/Projects/gemini app/style.css"})])
    run.generic("body {}")
    run.planner("I'll start with the layout.", tools=[("write_file", {"Path": HOME + "/Projects/gemini app/hero.html",
                                                                       "Content": "<section></section>"})])
    run.step("CHECKPOINT", source="CORTEX_STEP_SOURCE_SYSTEM", content="Checkpoint", input_tokens=2400,
             cache_read_tokens=900, output_tokens=10)
    run.generic("Wrote hero.html.")
    run.t = NOW - 130
    run.planner("Building the page now.", tools=[("run_command", {"CommandLine": "npm run build", "Cwd": AGY_CWD,
                                                                  "toolSummary": "Build the site"})],
                tokens=(2600, 1000, 40))
    run.write(root, tail='{"step_index": 99, "type": "GENERIC", "cont')

    ask = AgyLog("agy-ask-0002", NOW - 900)
    ask.user("Pick a colour scheme.")
    ask.planner("Two good options.", tools=[("ask_question", {"questions": json.dumps(
        [{"question": "Dark or light theme?", "options": ["Dark", "Light"]}])})])
    ask.write(root)

    idle = AgyLog("agy-idle-0003", NOW - 4000)
    idle.user("Deploy the preview.")
    idle.planner(tools=[("run_command", {"CommandLine": "npm run deploy"})])
    idle.generic("Deployed.")
    idle.planner("Deployed the preview. It is live on the staging site.", tokens=(500, 0, 25))
    idle.generic("")
    idle.write(root)

    quiet = AgyLog("agy-quiet-0007", NOW - 3600)
    quiet.user("Read the whole codebase.")
    quiet.planner(tools=[("read_resource", {"ServerName": "docs", "Uri": "docs://guide"})])
    quiet.write(root)

    # No row in the database (too old to list), so its tokens are filed under "Google Antigravity".
    ancient = AgyLog("agy-ancient-0006", NOW - 50 * 3600)
    ancient.user("An old conversation.")
    ancient.planner("Done long ago.", tokens=(300, 0, 15))
    ancient.write(root)

    tasks = os.path.join(root, AGY, "brain", "agy-run-0001", ".system_generated", "tasks")
    os.makedirs(tasks, exist_ok=True)
    with open(os.path.join(tasks, "task-7.log"), "w") as fh:
        fh.write("\x1b[32mbuilt\x1b[0m in 2s\n")
    open(os.path.join(tasks, "task-8.log"), "w").close()

    daemon = os.path.join(root, AGY, "daemon")
    os.makedirs(daemon, exist_ok=True)
    with open(os.path.join(daemon, "hub_50000.json"), "w") as fh:
        json.dump({"pid": 424242, "httpsPort": 50002, "httpPort": 50001, "lsVersion": "1.0.0"}, fh)
    with open(os.path.join(daemon, "hub_0.json"), "w") as fh:
        json.dump({"pid": 0, "httpPort": 1}, fh)
    with open(os.path.join(daemon, "hub_bad.json"), "w") as fh:
        fh.write("not json")

    app = os.path.join(root, "opt/Antigravity.app/Contents")
    os.makedirs(app, exist_ok=True)
    with open(os.path.join(app, "Info.plist"), "wb") as fh:
        plistlib.dump({"CFBundleShortVersionString": "1.2.3", "CFBundleName": "Antigravity"}, fh)

    path = os.path.join(root, AGY, "conversation_summaries.db")
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.execute("""CREATE TABLE `conversation_summaries` (`conversation_id` text,`title` text NOT NULL DEFAULT "",
        `preview` text NOT NULL DEFAULT "",`step_count` integer NOT NULL DEFAULT 0,`last_modified_time` datetime NOT NULL,
        `workspace_uris` text NOT NULL,`status` text NOT NULL DEFAULT "",`not_fully_idle` numeric NOT NULL DEFAULT false,
        `killed` numeric NOT NULL DEFAULT false,`last_user_input_time` datetime NOT NULL,PRIMARY KEY (`conversation_id`))""")
    uri = "file://" + AGY_CWD.replace(" ", "%20")
    rows = [
        ("agy-run-0001", "Build the landing page", NOW - 120, json.dumps([uri, "file:///fixture/other"]),
         "CASCADE_RUN_STATUS_RUNNING", 1, 0, agy_db_time(NOW - 1800)),
        ("agy-ask-0002", "Colours", NOW - 600, json.dumps([uri]), "CASCADE_RUN_STATUS_IDLE", 1, 0,
         agy_db_time(NOW - 900)),
        ("agy-idle-0003", "", NOW - 3600, json.dumps(["file:///fixture/Projects/site"]), "CASCADE_RUN_STATUS_IDLE",
         0, 0, agy_db_time(NOW - 4000)),
        ("agy-old-0004", "Old experiment. Never finished", NOW - 30 * 3600, "[]", "CASCADE_RUN_STATUS_IDLE", 0, 0,
         "not a time"),
        ("agy-killed-0005", "Killed", NOW - 60, "[]", "CASCADE_RUN_STATUS_IDLE", 0, 1, agy_db_time(NOW - 60)),
        ("agy-ancient-0006", "Ancient", NOW - 50 * 3600, "[]", "CASCADE_RUN_STATUS_IDLE", 0, 0, agy_db_time(NOW - 50 * 3600)),
        ("agy-quiet-0007", "", NOW - 2700, json.dumps(["vscode-remote://ssh-remote+box/srv/app"]),
         "CASCADE_RUN_STATUS_RUNNING", 0, 0, agy_db_time(NOW - 3600)),
        ("agy-badtime-0008", "Bad time", None, "not json", "CASCADE_RUN_STATUS_IDLE", 0, 0, agy_db_time(NOW - 60)),
    ]
    for sid, title, t, uris, status, busy, killed, last_input in rows:
        db.execute("insert into conversation_summaries (conversation_id, title, last_modified_time, workspace_uris, "
                   "status, not_fully_idle, killed, last_user_input_time) values (?,?,?,?,?,?,?,?)",
                   (sid, title, agy_db_time(t) if t else "yesterday", uris, status, busy, killed, last_input))
    db.commit()
    db.close()


def skills(root):
    def skill(folder, body):
        os.makedirs(os.path.join(root, folder), exist_ok=True)
        with open(os.path.join(root, folder, "SKILL.md"), "w") as fh:
            fh.write(body)

    skill(".claude/skills/demo-skill", "---\nname: demo-skill\ndescription: \"Says hello to the user.\"\n"
                                       "version: 1.4.2\n---\n# Demo\n")
    skill(".claude/skills/multi-line", "---\nname: multi-line\ndescription: |\n  First line of the\n"
                                       "  description.\nmetadata:\n  version: '0.3'\n---\nBody\n")
    skill(".claude/skills/no-front-matter", "Just a body.\n")
    os.makedirs(os.path.join(root, ".claude/skills/not-a-skill"), exist_ok=True)
    skill(".claude/skills/synced/acct-1/helper", "---\nname: helper\ndescription: Synced from the account.\n---\n")
    skill(".agents/skills/shared-one", "---\nname: shared-one\ndescription: Shared skill.\n---\n")
    skill(".claude/plugins/cache/market/toolkit/1.0.0/skills/lint", "---\nname: lint\ndescription: Lints code.\n---\n")
    skill(".claude/plugins/synced/acct/synced-plugin/skills/sync-skill", "---\nname: sync-skill\n---\n")
    skill("opt/openclaw/skills/claw-skill", "---\nname: claw-skill\ndescription: Bundled with OpenClaw.\n---\n")
    skill(".openclaw/skills/claw-local", "---\nname: claw-local\ndescription: Local OpenClaw skill.\n---\n")
    skill(".gemini/config/skills/agy-skill", "---\nname: agy-skill\ndescription: An Antigravity skill.\n---\n")
    skill(".gemini/antigravity/builtin/skills/agy-builtin",
          "---\nname: agy-builtin\ndescription: Ships with Antigravity.\nversion: 2.0.1\n---\n")

    def write_json(path, obj):
        os.makedirs(os.path.dirname(os.path.join(root, path)), exist_ok=True)
        with open(os.path.join(root, path), "w") as fh:
            json.dump(obj, fh, indent=2)

    write_json(".claude/plugins/installed_plugins.json", {"version": 2, "plugins": {
        "toolkit@market": [{"scope": "user", "installPath": HOME + "/.claude/plugins/cache/market/toolkit/1.0.0",
                            "version": "1.0.0", "lastUpdated": "2026-11-01T10:00:00.000Z"}],
        "solo@market": [{"scope": "user", "installPath": HOME + "/.claude/plugins/cache/market/solo/2.0.0",
                         "version": "2.0.0", "lastUpdated": "2026-11-02T10:00:00.000Z"}],
        "empty@market": []}})
    write_json(".claude/plugins/known_marketplaces.json", {"market": {
        "source": {"source": "github", "repo": "example/market"},
        "installLocation": HOME + "/.claude/plugins/marketplaces/market", "lastUpdated": "2026-11-05T10:00:00.000Z"}})
    write_json(".claude/plugins/marketplaces/market/.claude-plugin/marketplace.json", {"plugins": [
        {"name": "toolkit", "version": "1.2.0", "source": "./toolkit"},
        {"name": "solo", "source": "./solo"}]})
    write_json(".claude/plugins/marketplaces/market/solo/.claude-plugin/plugin.json", {"name": "solo", "version": "2.0.0"})
    write_json(".claude/plugins/synced/acct/synced-plugin/.claude-plugin/plugin.json",
               {"name": "Synced Plugin", "version": "3.1.0"})
    write_json(".claude/settings.json", {"enabledPlugins": {"solo@market": False}})
    write_json(".agents/.skill-lock.json", {"skills": {"shared-one": {"source": "github:example/skills",
                                                                     "updatedAt": "2026-11-03T08:00:00Z"}}})
    write_json("opt/openclaw/package.json", {"name": "openclaw", "version": "9.9.9"})


def openclaw(root):
    path = os.path.join(root, ".openclaw/state/openclaw.sqlite")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript("""
        create table task_runs (id integer primary key, label text, task text, status text, runtime text,
            agent_id text, created_at integer, started_at integer, ended_at integer, last_event_at integer,
            last_tool_name text, progress_summary text, error text, terminal_summary text);
        create table cron_jobs (id integer primary key, name text, enabled integer, job_json text, state_json text);
    """)
    ms = NOW * 1000
    rows = [
        ("Nightly digest", "digest", "running", "node", "main", ms - 600_000, ms - 600_000, None, ms - 60_000,
         "web_fetch", "Fetched 3 of 5 feeds", None, None),
        (None, "cleanup temp", "queued", "node", "main", ms - 120_000, None, None, None, None, None, None, None),
        ("Backup", "backup", "failed", "node", "main", ms - 7200_000, ms - 7200_000, ms - 7000_000, None, None,
         None, "disk full", None),
        ("Old failure", "old", "timed_out", "node", "main", ms - 9 * 86400_000, None, ms - 9 * 86400_000, None,
         None, None, "too slow", None),
        ("Nightly digest", "digest", "succeeded", "node", "main", ms - 80000_000, None, ms - 79000_000, None,
         None, None, None, "ok"),
    ]
    db.executemany("insert into task_runs (label, task, status, runtime, agent_id, created_at, started_at, ended_at, "
                   "last_event_at, last_tool_name, progress_summary, error, terminal_summary) "
                   "values (?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    db.executemany("insert into cron_jobs (name, enabled, job_json, state_json) values (?,?,?,?)", [
        ("digest", 1, json.dumps({"schedule": {"expr": "0 7 * * *"}}),
         json.dumps({"nextRunAtMs": ms + 3600_000, "lastRunAtMs": ms - 80000_000, "lastStatus": "ok"})),
        ("paused job", 0, "not json", None)])
    db.commit()
    db.close()


def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "Tests/HiveCoreTests/Fixtures/home")
    for sub in (".claude", ".agents", ".openclaw", ".gemini", "opt"):
        shutil.rmtree(os.path.join(root, sub), ignore_errors=True)
    os.makedirs(root, exist_ok=True)
    main_session(root)
    asked_session(root)
    done_session(root)
    big_session(root)
    usage_session(root)
    small_sessions(root)
    questions_session(root)
    antigravity(root)
    skills(root)
    openclaw(root)
    # A session file and a .key file beside it; tests add live session files of their own.
    os.makedirs(os.path.join(root, ".claude/sessions"), exist_ok=True)
    with open(os.path.join(root, ".claude/sessions/999999.json"), "w") as fh:
        json.dump({"pid": 999999, "sessionId": "sess-dead-0010", "cwd": DEMO, "status": "idle"}, fh)
    with open(os.path.join(root, ".claude/sessions/999999.0123abcd.key"), "w") as fh:
        fh.write("not a secret, but never read")
    print("wrote", root)


if __name__ == "__main__":
    main()

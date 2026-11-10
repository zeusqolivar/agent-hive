#!/usr/bin/env python3
"""Generate the expected JSON for the contract tests by running server.py on the fixture home.

Usage: python3 scripts/make_contract_fixtures.py <path to server.py> <fixture home>

The fixture home is copied to a temporary folder with `__HOME__` replaced by that folder's path and
every file's modification time set to NOW - 60 s. server.py is imported by path with its home, folders
and clock pointed at the copy, and its outputs are written to `<fixture home>/../expected/`, with the
temporary path turned back into `__HOME__`. The Swift tests prepare the same copy the same way.
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time as real_time

sys.dont_write_bytecode = True   # leave no __pycache__ beside server.py

NOW = 1794312000
# Antigravity's app process in the fixture. macOS pids stay below 100000, so it can't be a real process; the
# fixture's pid check treats it as alive.
AGY_PID = 424242
PROCESSES = {
    AGY_PID: {"pid": AGY_PID, "ppid": 1, "uptime": 7200, "rssMB": 900, "cpu": 4.5,
              "cmd": "/Applications/Antigravity.app/Contents/MacOS/Antigravity"},
    AGY_PID + 1: {"pid": AGY_PID + 1, "ppid": AGY_PID, "uptime": 7100, "rssMB": 300, "cpu": 1.5,
                  "cmd": "/Applications/Antigravity.app/Contents/Resources/bin/language_server --port 1"},
    AGY_PID + 2: {"pid": AGY_PID + 2, "ppid": AGY_PID + 1, "uptime": 60, "rssMB": 80, "cpu": 30.0,
                  "cmd": "/bin/zsh -c npm run build"},
}
TEXT_SUFFIXES = (".json", ".jsonl", ".md")


def prepare_home(src, dst):
    shutil.copytree(src, dst, dirs_exist_ok=True)
    for folder, dirs, files in os.walk(dst):
        for name in files:
            path = os.path.join(folder, name)
            if name.endswith(TEXT_SUFFIXES):
                with open(path, "rb") as fh:
                    data = fh.read()
                if b"__HOME__" in data:
                    with open(path, "wb") as fh:
                        fh.write(data.replace(b"__HOME__", dst.encode()))
            os.utime(path, (NOW - 60, NOW - 60))


class FixedClock:
    """Stands in for the time module inside server.py so 'now' is NOW."""

    def __getattr__(self, name):
        return getattr(real_time, name)

    def time(self):
        return float(NOW)

    def localtime(self, t=None):
        return real_time.localtime(NOW if t is None else t)

    def gmtime(self, t=None):
        return real_time.gmtime(NOW if t is None else t)

    def strftime(self, fmt, t=None):
        return real_time.strftime(fmt, self.localtime() if t is None else t)


def load_server(path, home):
    os.environ["HOME"] = home
    os.environ["TZ"] = "UTC"
    real_time.tzset()
    spec = importlib.util.spec_from_file_location("hive_server", path)
    server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server)
    server.time = FixedClock()
    server.HOME = home
    server.SESSIONS_DIR = os.path.join(home, ".claude/sessions")
    server.PROJECTS_DIR = os.path.join(home, ".claude/projects")
    server.PLUGINS_DIR = os.path.join(home, ".claude/plugins")
    server.OPENCLAW_DB = os.path.join(home, ".openclaw/state/openclaw.sqlite")
    server.ANTIGRAVITY_DIR = os.path.join(home, ".gemini/antigravity")
    server.ANTIGRAVITY_DB = os.path.join(server.ANTIGRAVITY_DIR, "conversation_summaries.db")
    server.ANTIGRAVITY_APP = os.path.join(home, "opt/Antigravity.app")
    real_pid_alive = server.pid_alive
    server.pid_alive = lambda pid: pid == AGY_PID or real_pid_alive(pid)
    server.ps_table = lambda: {pid: dict(p) for pid, p in PROCESSES.items()}
    opt = "/opt/homebrew/lib/node_modules/openclaw"
    fixture_opt = os.path.join(home, "opt/openclaw")
    server.SKILL_ROOTS = [(label, root.replace(opt, fixture_opt)) for label, root in server.SKILL_ROOTS]
    original_read_json = server.read_json
    server.read_json = lambda p, default=None: original_read_json(str(p).replace(opt, fixture_opt), default)
    return server


def main():
    server_path, fixture_home = sys.argv[1], os.path.abspath(sys.argv[2])
    out_dir = os.path.join(os.path.dirname(fixture_home), "expected")
    os.makedirs(out_dir, exist_ok=True)
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="hive-contract-"))
    home = os.path.join(tmp, "home")
    prepare_home(fixture_home, home)
    server = load_server(server_path, home)

    def dump(name, obj):
        text = json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True).replace(home, "__HOME__")
        with open(os.path.join(out_dir, name), "w") as fh:
            fh.write(text + "\n")

    projects = os.path.join(home, ".claude/projects")
    demo = os.path.join(projects, "-fixture-Projects-demo")
    other = os.path.join(projects, "-fixture-Projects-other")
    subs_dir = os.path.join(demo, "sess-main-0001", "subagents")
    transcripts = {
        "main": os.path.join(demo, "sess-main-0001.jsonl"),
        "asked": os.path.join(demo, "sess-asked-0002.jsonl"),
        "done": os.path.join(demo, "sess-done-0003.jsonl"),
        "big": os.path.join(other, "sess-big-0004.jsonl"),
        "usage": os.path.join(other, "sess-usage-0005.jsonl"),
        "question": os.path.join(demo, "sess-question-0006.jsonl"),
        "plan": os.path.join(demo, "sess-plan-0007.jsonl"),
        "planned": os.path.join(demo, "sess-planned-0009.jsonl"),
        "questions": os.path.join(demo, "sess-questions-0011.jsonl"),
        "agent-running": os.path.join(subs_dir, "agent-a1b2c3d4.jsonl"),
        "agent-done": os.path.join(subs_dir, "agent-e5f6a7b8.jsonl"),
    }
    tails = {}
    for name, path in transcripts.items():
        tails[name] = server.read_transcript(path)
        dump(f"transcript-{name}.json", {"file": path, "tail": tails[name]})

    def describe_case(name, raw, transcript, subs=0, commands=()):
        tail = tails[transcript] if transcript else None
        commands = [{"pid": 1, "uptime": 5, "cpu": 0.0, "rssMB": 1, "cmd": c} for c in commands]
        group, reason, headline = server.describe(raw, tail, subs, commands)
        dump(f"describe-{name}.json", {
            "input": {"raw": raw, "transcript": transcript, "subsRunning": subs, "commands": commands},
            "group": group, "reason": reason, "headline": headline,
            "doing": server.doing_of(group, tail, subs, commands),
            "questions": server.questions_of(tail) if hasattr(server, "questions_of") else []})

    describe_case("busy-pending-bash", {"status": "busy"}, "main", subs=1)
    describe_case("busy-subagents", {"status": "busy"}, "planned", subs=2)
    describe_case("busy-pending-agent-one-sub", {"status": "busy"}, "question", subs=1)
    describe_case("busy-ended-idle", {"status": "busy"}, "done")
    describe_case("busy-ended-command", {"status": "busy"}, "done", commands=["/bin/zsh -c npm run dev"])
    describe_case("busy-ended-asked", {"status": "busy"}, "asked", commands=["/bin/zsh -c npm run dev"])
    describe_case("busy-plan-current", {"status": "busy"}, "planned")
    describe_case("busy-no-transcript", {"status": "busy"}, None)
    describe_case("waiting-permission", {"status": "waiting", "waitingFor": "permission prompt"}, "main")
    describe_case("waiting-permission-none", {"status": "waiting", "waitingFor": "permission prompt"}, "done")
    describe_case("waiting-question", {"status": "waiting", "waitingFor": "input"}, "question")
    describe_case("waiting-plan", {"status": "waiting"}, "plan")
    describe_case("waiting-other", {"status": "waiting", "waitingFor": "a sandbox decision"}, "done")
    describe_case("waiting-nothing", {"status": "waiting"}, None)
    describe_case("idle-asked", {"status": "idle"}, "asked")
    describe_case("idle-recap", {"status": "idle"}, "done")
    describe_case("idle-last-text", {"status": "idle"}, "big")
    describe_case("idle-nothing", {"status": "idle"}, None)
    describe_case("busy-ended-questions", {"status": "busy"}, "questions", commands=["/bin/zsh -c npm run dev"])
    describe_case("idle-questions", {"status": "idle"}, "questions")
    describe_case("waiting-questions", {"status": "waiting", "waitingFor": "permission prompt"}, "questions")

    agents = server.list_subagents(transcripts["main"])
    dump("subagents-main.json", {"list": agents, "helpers": server.helper_views(agents),
                                 "views": [server.subagent_view(a, with_last=True) for a in agents]})
    dump("subagents-asked.json", {"list": server.list_subagents(transcripts["asked"]), "helpers": []})

    dump("live-main.json", {"items": server.parse_live(transcripts["main"])})
    dump("live-agent.json", {"items": server.parse_live(transcripts["agent-running"], "Find the parser callers")})

    agy = os.path.join(home, ".gemini/antigravity/brain")
    agy_runs = {"agy-run": "agy-run-0001", "agy-ask": "agy-ask-0002", "agy-idle": "agy-idle-0003",
                "agy-quiet": "agy-quiet-0007"}
    for name, sid in agy_runs.items():
        path = os.path.join(agy, sid, ".system_generated/logs/transcript.jsonl")
        dump(f"transcript-{name}.json", {"file": path, "tail": server.read_transcript(path)})
    run_log = os.path.join(agy, "agy-run-0001/.system_generated/logs/transcript.jsonl")
    dump("live-agy-run.json", {"items": server.parse_live(run_log)})
    dump("live-agy-sub.json", {"items": server.parse_live(run_log, "A helper")})
    pairs = server.read_antigravity_sessions(server.ps_table())
    dump("antigravity-sessions.json", {"processes": list(PROCESSES.values()),
                                       "rows": [row for row, _ in pairs], "raws": [raw for _, raw in pairs]})

    server.usage_pass()
    report = server.usage_report()
    report["perSession"] = {sid: server.usage_for_session(sid)
                            for sid in ("sess-main-0001", "sess-usage-0005", "sess-missing-0000", "agy-run-0001",
                                        "agy-ancient-0006")}
    dump("usage.json", report)
    dump("skills.json", server.skills_report())
    dump("openclaw.json", server.openclaw_summary())

    # The whole board, with the fixture's processes, for the Antigravity rows, their details and feeds.
    server.build_board()
    rows = [r for r in server._board["sessions"] if r.get("provider") == "google"]
    dump("board-antigravity.json", {"processes": list(PROCESSES.values()), "rows": rows,
                                    "ids": [r["id"] for r in server._board["sessions"]]})
    dump("detail-agy-run.json", server.session_detail("agy-run-0001"))
    dump("detail-agy-idle.json", server.session_detail("agy-idle-0003"))
    dump("live-report-agy-run.json", server.live_report("agy-run-0001"))
    dump("activity.json", {"items": server.activity_feed()})
    shutil.rmtree(tmp)
    print("wrote", out_dir)


if __name__ == "__main__":
    main()

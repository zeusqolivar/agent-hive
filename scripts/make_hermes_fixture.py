"""Builds the Hermes fixture database: three sessions with the columns the reader uses.

Made up entirely: no real session, title, path or message from anyone's PC.
"""
import sqlite3
from pathlib import Path

OUT = Path("Tests/HiveCoreTests/Fixtures/hermes-home/state.db")
NOW = 1_794_320_000


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        OUT.unlink()
    db = sqlite3.connect(OUT)
    db.executescript(
        """
        create table sessions (
            id text primary key, title text, display_name text, model text,
            started_at real, ended_at real, last_activity_at real,
            last_activity_description text, message_count integer,
            cwd text, git_branch text, archived integer default 0, hidden integer default 0,
            profile_name text
        );
        create table messages (
            id integer primary key autoincrement, session_id text, role text, content text,
            timestamp real
        );
        """
    )
    sessions = [
        # id, title, display, model, started, ended, last_activity, description, messages, cwd, branch
        ("hermes-busy-0001", "Port the board to Windows", None, "deepseek-flash",
         NOW - 3600, None, NOW - 30, "receiving stream response", 812, r"C:\Users\me\projects\agent-hive", "windows-port"),
        ("hermes-idle-0002", "Weekly review", "Zeus", "deepseek-flash",
         NOW - 7200, None, NOW - 5400, None, 40, None, None),
        ("hermes-ended-0003", "Subagent: check the fixtures", None, "deepseek-flash",
         NOW - 9000, NOW - 8000, NOW - 8100, None, 12, r"C:\Users\me\scratch", None),
        # Hidden and archived sessions must not appear.
        ("hermes-hidden-0004", "Hidden", None, "deepseek-flash",
         NOW - 100, None, NOW - 60, "x", 1, None, None),
    ]
    for sid, title, display, model, started, ended, last, description, count, cwd, branch in sessions:
        hidden = 1 if sid == "hermes-hidden-0004" else 0
        db.execute(
            "insert into sessions (id, title, display_name, model, started_at, ended_at, last_activity_at,"
            " last_activity_description, message_count, cwd, git_branch, archived, hidden, profile_name)"
            " values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 'default')",
            (sid, title, display, model, started, ended, last, description, count, cwd, branch, hidden),
        )
    db.execute("insert into messages (session_id, role, content, timestamp) values (?, 'assistant', ?, ?)",
               ("hermes-idle-0002", "The week is planned: three posts and one review.\nMore detail follows.", NOW - 5400))
    db.execute("insert into messages (session_id, role, content, timestamp) values (?, 'user', ?, ?)",
               ("hermes-idle-0002", "Plan my week", NOW - 7000))
    db.commit()
    db.close()
    print(f"{OUT}: {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()

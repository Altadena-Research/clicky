"""Discover local Wispr recordings and open the matching interactive Claude session."""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid

from wispr_activity import activity_columns, resumed_segment, timestamp_seconds

HOME = Path.home()
DATA = Path(os.environ.get("WISPR_DATA_DIR", HOME / "Library/Application Support/Wispr Flow"))
PREFERENCES = Path(os.environ.get("CLICKY_STATE_DIR", HOME / ".local/state/clicky-meeting"))
CURSORS = Path(os.environ.get("WISPR_MEETING_STATE_DIR", HOME / ".local/state/wispr-meeting"))
CONFIG = Path(os.environ.get("CLAUDE_CONFIG_DIR", HOME / ".claude"))
CONNECT_TIMEOUT = 120


def recordings():
    database = DATA / "flow.sqlite"
    if not database.is_file():
        return {}
    with contextlib.closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=.4)) as db:
        columns = {row[1] for row in db.execute("PRAGMA table_info(Meetings)")}
        if not columns:
            return {}
        db.row_factory = sqlite3.Row
        candidates = "(finalized = 0 AND endedAt IS NULL)"
        if "serverRecordingLive" in columns:
            candidates += " OR serverRecordingLive = 1"
        conditions = ["COALESCE(isDeleted, 0) = 0", "(" + candidates + ")"]
        if "isTourDemo" in columns:
            conditions.append("COALESCE(isTourDemo, 0) = 0")
        if "importSource" in columns:
            conditions.append("importSource IS NULL")
        fields = "id, title, createdAt, finalized, endedAt, " + activity_columns(columns)
        rows = db.execute("SELECT " + fields + " FROM Meetings WHERE " + " AND ".join(conditions))
        active = {}
        for row in rows:
            try:
                identifier = str(uuid.UUID(row["id"]))
                segment = resumed_segment(DATA, row)
                if not segment and (row["finalized"] or row["endedAt"] is not None):
                    continue
                folder = DATA / "meetings" / identifier
                # A local recording creates its own directory. Synced and calendar-only
                # entries aren't evidence that this Mac is capturing the meeting.
                changed = folder.stat().st_mtime
                for path in folder.iterdir():
                    with contextlib.suppress(OSError):
                        changed = max(changed, path.stat().st_mtime)
                changed = max(changed, timestamp_seconds(row["createdAt"]) or 0)
                if time.time() - changed < 600:
                    active[identifier] = (row["title"] or "Wispr meeting", segment)
            except (FileNotFoundError, ValueError, TypeError, AttributeError):
                continue
        return active


def read_object(path):
    try:
        return json.loads(path.read_bytes())
    except (OSError, ValueError):
        return {}


def live_sessions():
    sessions = {}
    for path in (CONFIG / "sessions").glob("*.json"):
        entry = read_object(path)
        try:
            session = str(uuid.UUID(entry["sessionId"]))
            pid = int(entry["pid"])
            if pid <= 0 or path.stem != str(pid):
                continue
            os.kill(pid, 0)
        except (OSError, KeyError, ValueError, TypeError):
            continue
        sessions[session] = entry.get("name") or Path(entry.get("cwd") or "~").name
    return sessions


def matches(meeting, paired, live):
    candidates = dict.fromkeys(paired, "Paired conversation")
    candidates.update(live)
    result = {}
    for session, label in candidates.items():
        cursor = read_object(CURSORS / (session + ".json"))
        if cursor.get("meeting_id") == meeting and not cursor.get("stopped"):
            result[session] = label
    return result


def request_pairing(session, meeting):
    cursor = read_object(CURSORS / (session + ".json"))
    generation = cursor.get("generation") if cursor.get("meeting_id") == meeting else None
    CURSORS.mkdir(exist_ok=True, parents=True, mode=0o700)
    path = CURSORS / (session + ".clicky-request")
    with tempfile.NamedTemporaryFile(mode="w", dir=CURSORS, delete=False) as output:
        json.dump({"meeting": meeting, "generation": generation, "expires": time.time() + CONNECT_TIMEOUT}, output)
    os.replace(output.name, path)


def launch_claude(session, meeting, project):
    search = os.pathsep.join([os.environ.get("PATH", ""), str(HOME / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"])
    cli = shutil.which("claude", path=search)
    if not cli:
        raise ValueError("Install Claude Code to open a meeting conversation.")
    if not (CONFIG / "skills/meeting/scripts/meeting.py").is_file() or not (CONFIG / "skills/clicky-meeting/bridge.py").is_file():
        raise ValueError("Install the local /meeting and /clicky-meeting skills before opening a meeting.")
    # Launch Services opens a real interactive terminal so first-run permissions
    # and normal Claude prompts remain visible. No keystrokes go to other windows.
    with tempfile.NamedTemporaryFile(mode="w", suffix=".command", prefix="Open Meeting ", dir=PREFERENCES, delete=False) as file:
        script = Path(file.name)
        command = [cli, "--session-id", session, "--name", "Clicky Meeting", "--", "/meeting use " + meeting]
        file.write('#!/bin/zsh\n/bin/rm -f -- "$0"\n')
        for name in ("WISPR_DATA_DIR", "WISPR_MEETING_STATE_DIR", "CLICKY_RUNTIME_DIR", "CLAUDE_CONFIG_DIR"):
            if name in os.environ:
                file.write("export " + name + "=" + shlex.quote(os.environ[name]) + "\n")
        file.write("cd -- " + shlex.quote(str(project)) + " || exit 1\nexec " + shlex.join(command) + "\n")
    script.chmod(0o700)
    application = "com.googlecode.iterm2" if Path("/Applications/iTerm.app").exists() else "com.apple.Terminal"
    try:
        subprocess.run(["/usr/bin/open", "-b", application, str(script)], check=True, capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        script.unlink(missing_ok=True)
        raise ValueError("Couldn’t open the terminal for this meeting.") from error


class Invitations:
    def __init__(self):
        PREFERENCES.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(PREFERENCES / "invitations.sqlite", isolation_level=None)
        self.db.execute("CREATE TABLE IF NOT EXISTS invitations (meeting TEXT PRIMARY KEY, status TEXT, session TEXT, since REAL)")
        self.db.execute("BEGIN IMMEDIATE")
        try:
            if "segment" not in {row[1] for row in self.db.execute("PRAGMA table_info(invitations)")}:
                self.db.execute("ALTER TABLE invitations ADD COLUMN segment INTEGER NOT NULL DEFAULT 0")
            self.db.execute("COMMIT")
        except sqlite3.Error:
            self.db.execute("ROLLBACK")
            raise
        self.choices = {}
        self.next_selection = None
        self.active = {}
        self.scan_after = 0
        self.problem = None
        self.project = read_object(PREFERENCES / "project.json").get("path", str(HOME))
        self.restored = False

    def set_project(self, value):
        folder = Path(value).expanduser().resolve()
        if not folder.is_dir():
            raise ValueError("Choose an existing project folder.")
        with tempfile.NamedTemporaryFile(mode="w", dir=PREFERENCES, delete=False) as output:
            json.dump({"path": str(folder)}, output)
        os.replace(output.name, PREFERENCES / "project.json")
        self.project = str(folder)

    def refresh(self, force=False):
        if not force and time.monotonic() < self.scan_after:
            return
        self.scan_after = time.monotonic() + 3
        try:
            self.active = recordings()
            self.problem = None
        except (sqlite3.Error, OSError) as error:
            self.active = {}
            self.problem = "Couldn’t read Wispr’s recording status: " + str(error)

    def view(self, paired):
        self.refresh()
        rows = self.db.execute("SELECT meeting, status, session, since, segment FROM invitations ORDER BY since DESC").fetchall()
        saved = {}
        for meeting, status, session, since, previous_segment in rows:
            active = self.active.get(meeting)
            if active and active[1] != previous_segment:
                cursor = read_object(CURSORS / (session + ".json")) if session in paired else {}
                if cursor.get("meeting_id") == meeting and not cursor.get("stopped"):
                    self.db.execute("UPDATE invitations SET segment=?, status='opened' WHERE meeting=? AND segment=?",
                                    (active[1], meeting, previous_segment))
                    self.next_selection, status = session, "opened"
                else:
                    continue
            if status in ("opening", "retry") and session in paired:
                cursor = read_object(CURSORS / (session + ".json"))
                if cursor.get("meeting_id") == meeting and not cursor.get("stopped"):
                    self.db.execute("UPDATE invitations SET status='opened' WHERE meeting=?", (meeting,))
                    self.next_selection, status = session, "opened"
            if status == "opening" and time.time() - since > CONNECT_TIMEOUT:
                self.db.execute("UPDATE invitations SET status='retry' WHERE meeting=?", (meeting,))
                status = "retry"
            if (not self.restored and self.next_selection is None and status == "opened" and session in paired
                    and read_object(CURSORS / (session + ".json")).get("meeting_id") == meeting):
                self.next_selection = session
            saved[meeting] = status
        self.restored = True
        for meeting, (title, segment) in self.active.items():
            status = saved.get(meeting, "new")
            if status not in ("dismissed", "opened"):
                return {"id": meeting, "title": title, "segment": segment, "status": status, "choices": self.choices.get((meeting, segment), {})}
        return None

    def respond(self, op, meeting, selected, paired, expected_segment=None):
        meeting = str(uuid.UUID(meeting))
        self.refresh(force=True)
        if meeting not in self.active:
            raise ValueError(self.problem or "This recording has ended.")
        segment = self.active[meeting][1]
        if expected_segment is not None and int(expected_segment) != segment:
            raise ValueError("The recording changed. Use the current invitation.")
        self.db.execute("BEGIN IMMEDIATE")
        request = None
        try:
            prior = self.db.execute("SELECT status,session FROM invitations WHERE meeting=? AND segment=?", (meeting, segment)).fetchone()
            if op == "dismiss":
                if prior and prior[0] in ("opening", "opened"):
                    raise ValueError("This conversation is already opening.")
                status, session = "dismissed", None
            else:
                if prior and prior[0] in ("opening", "dismissed", "opened"):
                    self.db.execute("COMMIT")
                    return
                live = live_sessions()
                existing = matches(meeting, paired, live)
                if selected and selected not in existing:
                    raise ValueError("That session is no longer following this meeting.")
                if len(existing) > 1 and not selected:
                    self.choices[meeting, segment] = existing
                    self.db.execute("COMMIT")
                    return
                session = selected or next(iter(existing), None)
                if session in paired:
                    status, self.next_selection = "opened", session
                else:
                    if session is None and prior and prior[0] == "retry":
                        # A trust prompt may be waiting before /meeting has a cursor.
                        if prior[1] in live and not (CURSORS / (prior[1] + ".json")).exists():
                            session = prior[1]
                    launch = session is None
                    session = session or str(uuid.uuid4())
                    if launch and not Path(self.project).is_dir():
                        raise ValueError("The meeting project moved. Choose its folder from the Clicky menu.")
                    request_pairing(session, meeting)
                    request = CURSORS / (session + ".clicky-request")
                    if launch:
                        launch_claude(session, meeting, self.project)
                    status = "opening"
            self.db.execute("INSERT OR REPLACE INTO invitations(meeting,status,session,since,segment) VALUES(?,?,?,?,?)",
                            (meeting, status, session, time.time(), segment))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            if request:
                request.unlink(missing_ok=True)
            raise

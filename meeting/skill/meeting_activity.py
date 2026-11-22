"""Read local activity records belonging to the selected meeting conversation."""
from __future__ import annotations

import contextlib
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import time

from recordings import CONFIG
from chat_controls import phase

FINISHED = {"completed", "failed", "stopped"}
STATES = {"completed": "completed", "failed": "failed", "killed": "stopped", "stopped": "stopped",
          "cancelled": "stopped", "canceled": "stopped", "running": "running", "queued": "queued"}
NOTICE = re.compile(r"<task-notification>\s*<task-id>([\w.-]+)</task-id>(.*?)</task-notification>", re.S)
STATUS = re.compile(r"<status>([\w-]+)</status>")
CODEX_LAUNCH = re.compile(r"^Codex [^\n]{1,70} started in the background as ([a-z]+-[a-z0-9-]+)\.", re.M)


def item(identifier, kind, title, status, updated=None, detail=None, thread=None, *, started=None, ended=None):
    return {"id": kind + ":" + identifier, "reference": identifier, "kind": kind, "title": title,
            "status": status, "updated": updated, "detail": detail, "thread": thread,
            "startedAt": started, "endedAt": ended}


def moment(value):
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError, OverflowError):
        return 0


def update_task(task, status, when):
    task.update(status=status, updated=when)
    if status in FINISHED and task["endedAt"] is None:
        task["endedAt"] = moment(when) or None


class MeetingActivity:
    def __init__(self, plugin_state=None, codex_home=None):
        self.plugin_state = plugin_state or CONFIG / "plugins/data/codex-openai-codex/state"
        self.codex_home = codex_home or Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
        self.session = None
        self.reset(None, None)

    def reset(self, session, identity):
        self.session, self.identity = session, identity
        self.offset = 0
        self.tools = {}
        self.tasks = {}
        self.deadlines = {}
        self.directories = set()
        self.job_titles = {}
        self.watched_jobs = {}
        self.watch_calls = {}
        self.files = {}
        self.refresh_at = 0
        self.jobs = []
        self.agents = []
        self.agent_calls = set()
        self.windows = {}
        self.turns = {}

    def consume(self, row):
        if row.get("sessionId") != self.session or row.get("isSidechain"):
            return
        cwd = row.get("cwd")
        if isinstance(cwd, str) and Path(cwd).is_absolute():
            self.directories.add(cwd)
        when = row.get("timestamp")
        content = (row.get("message") or {}).get("content")
        if row.get("type") == "user" and isinstance(content, str) and (row.get("origin") or {}).get("kind") == "task-notification":
            note = NOTICE.search(content)
            if note and note[1] in self.tasks:
                status = STATUS.search(note[2].split("<summary>", 1)[0])
                task = self.tasks[note[1]]
                if status and status[1] in STATES:
                    update_task(task, STATES[status[1]], when)
                else:
                    task["updated"] = when
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict):
                continue
            if row.get("type") == "assistant" and block.get("type") == "tool_use":
                name = block.get("name")
                if name in ("Agent", "Task", "Monitor", "Bash", "TaskStop"):
                    args = block.get("input") or {}
                    title = str(args.get("description") or "")[:160]
                    started = moment(when) or None
                    self.tools[block["id"]] = (name, title, started)
                    command = args.get("command", "") if name == "Bash" else ""
                    if "codex-companion.mjs" in command and re.search(r"\bstatus\b", command):
                        jobs = set(re.findall(r"\btask-[a-z0-9]+-[a-z0-9]+\b", command))
                        if len(jobs) == 1:
                            self.watch_calls[block["id"]] = jobs.pop()
                    if name in ("Agent", "Task"):
                        self.tasks[block["id"]] = item(block["id"], "claudeAgent", title or "Claude agent",
                                                       "running", when, args.get("subagent_type"), started=started)
            if row.get("type") != "user" or block.get("type") != "tool_result":
                continue
            tool = self.tools.get(block.get("tool_use_id"))
            result = row.get("toolUseResult")
            if not tool:
                continue
            call = block.get("tool_use_id")
            if block.get("is_error") and call in self.tasks:
                update_task(self.tasks[call], "failed", when)
                self.tools.pop(call, None)
                continue
            if not isinstance(result, dict):
                continue
            self.tools.pop(block.get("tool_use_id"), None)
            name, title, started = tool
            if name == "TaskStop":
                task = self.tasks.get(result.get("task_id"))
                if task and not block.get("is_error"):
                    update_task(task, "stopped", when)
                continue
            if name == "Monitor":
                ident, kind, state = result.get("taskId"), "listener", "listening"
            elif name == "Bash":
                ident, kind, state = result.get("backgroundTaskId"), "shell", "running"
                watched = self.watch_calls.pop(call, None)
                if watched and ident:
                    self.watched_jobs[ident] = watched
                launch = CODEX_LAUNCH.search(str(result.get("stdout") or "")[:2048])
                if launch and title:
                    self.job_titles[launch[1]] = title
            else:
                ident, kind = result.get("agentId"), "claudeAgent"
                state = "running" if result.get("isAsync") else STATES.get(result.get("status"), "unknown")
                if ident:
                    self.tasks.pop(call, None)
                elif call in self.tasks:
                    update_task(self.tasks[call], state, when)
            if isinstance(ident, str) and ident:
                self.tasks[ident] = item(ident, kind, title or {"listener": "Monitor", "shell": "Background command",
                                         "claudeAgent": "Claude agent"}[kind], state, when, started=started,
                                         ended=(moment(when) or None) if state in FINISHED else None)
                timeout = result.get("timeoutMs")
                if kind == "listener" and isinstance(timeout, (int, float)) and timeout > 0:
                    self.deadlines[ident] = moment(when) + timeout / 1000

    def read_transcript(self, session, log):
        try:
            st = log.stat() if log else None
            identity = (log, st.st_dev, st.st_ino) if st else None
            if session != self.session or identity != self.identity or (st and st.st_size < self.offset):
                self.reset(session, identity)
            if not st or self.offset == st.st_size:
                return
            with log.open("rb") as stream:
                stream.seek(self.offset)
                for line in stream:
                    if not line.endswith(b"\n"):
                        break
                    self.offset += len(line)
                    if b'"tool_use"' not in line and b'"tool_result"' not in line and b'task-notification' not in line:
                        continue
                    try:
                        self.consume(json.loads(line))
                    except (ValueError, TypeError, KeyError, AttributeError):
                        continue
        except OSError:
            if session != self.session:
                self.reset(session, None)

    def claude_agents(self, log):
        self.agent_calls = set()
        if not log:
            return []
        result = []
        for path in (log.with_suffix("") / "subagents").glob("agent-*.meta.json"):
            try:
                data = json.loads(path.read_bytes())
                ident = path.name[len("agent-"):-len(".meta.json")]
                recorded = self.tasks.get(ident, {})
                if data.get("toolUseId"):
                    self.agent_calls.add(data["toolUseId"])
                    recorded = recorded or self.tasks.get(data["toolUseId"], {})
                status = recorded.get("status", "unknown")
                if status not in FINISHED:
                    if data.get("finished") is True:
                        status = "completed"
                    elif data.get("finished") is False or data.get("toolUseId") in self.tools:
                        status = "running"
                result.append(item(ident, "claudeAgent", data.get("description") or recorded.get("title") or "Claude agent",
                                   status, recorded.get("updated"), data.get("agentType"),
                                   started=recorded.get("startedAt"), ended=recorded.get("endedAt")))
            except (OSError, ValueError, AttributeError):
                continue
        return result

    def records(self, path):
        previous, records = self.files.get(path, (None, []))
        try:
            stat = path.stat()
            stamp = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
            if stamp != previous:
                data = json.loads(path.read_bytes())
                source = data.get("jobs", []) if path.name == "state.json" else [data]
                records = [{key: job.get(key) for key in ("id", "title", "status", "pid", "updatedAt", "phase", "threadId", "workspaceRoot",
                                                          "startedAt", "createdAt", "completedAt")}
                           for job in source if isinstance(job, dict) and job.get("sessionId") == self.session and isinstance(job.get("id"), str)]
                self.files[path] = (stamp, records)
        except FileNotFoundError:
            self.files.pop(path, None)
            return []
        except (OSError, ValueError, AttributeError):
            pass  # A worker may still be rewriting the registry. Keep the last complete snapshot.
        return records

    def codex_jobs(self):
        paths = set()
        for directory in self.directories:
            cwd = Path(directory)
            # The companion keys a Git checkout by its worktree root, and other folders by their real path.
            root = next((p for p in (cwd, *cwd.parents) if (p / ".git").exists()), cwd)
            roots = {root, cwd}
            for folder in roots:
                slug = re.sub(r"[^a-zA-Z0-9._-]+", "-", folder.name).strip("-") or "workspace"
                key = hashlib.sha256(os.fsencode(os.path.realpath(folder))).hexdigest()[:16]
                paths.add(self.plugin_state / (slug + "-" + key) / "state.json")
        jobs = {j["id"]: j for path in sorted(paths) for j in self.records(path)}
        # A shell can launch a job from another cwd without changing Claude's own working directory.
        for ident in self.job_titles.keys() - jobs.keys():
            for path in self.plugin_state.glob("*/jobs/" + ident + ".json"):
                jobs.update((j["id"], j) for j in self.records(path))
        found = {}
        self.windows = {}
        for ident, job in jobs.items():
            status = STATES.get(job.get("status"), "unknown")
            pid = job.get("pid")
            if status in ("running", "queued") and isinstance(pid, int) and pid > 0:
                try:
                    os.kill(pid, 0)
                except (ProcessLookupError, OverflowError):
                    status = "unknown"
                except PermissionError:
                    pass
            # The summary can contain the memo itself. Use the launch description or the job's label.
            title = self.job_titles.get(ident) or job.get("title") or "Codex job"
            detail = " · ".join(x for x in (Path(job.get("workspaceRoot") or "").name, job.get("phase")) if x)
            found[ident] = item(ident, "codexJob", title, status, job.get("updatedAt"), detail, job.get("threadId"),
                                started=moment(job.get("startedAt")) or None, ended=moment(job.get("completedAt")) or None)
            if job.get("threadId"):
                start = moment(job.get("startedAt") or job.get("createdAt"))
                end = float("inf") if status in ("queued", "running") else moment(job.get("completedAt") or job.get("updatedAt"))
                if start and end >= start:
                    self.windows.setdefault(job["threadId"], []).append((int(start), int(end) + 1 if end != float("inf") else end))
        return list(found.values())

    def codex_children(self, jobs):
        roots = {job["thread"] for job in jobs if job.get("thread")}
        if not roots:
            return []
        databases = [p for p in self.codex_home.glob("state_*.sqlite") if p.stem[6:].isdigit()]
        if not databases:
            return []
        children = []
        try:
            path = max(databases, key=lambda p: int(p.stem[6:]))
            with contextlib.closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=.1)) as db:
                # Only descend from thread IDs attributed to this exact Claude session by its companion.
                pending = list(roots)
                seen = set(roots)
                while pending:
                    parent = pending.pop()
                    rows = db.execute("""SELECT t.id, t.agent_nickname, t.agent_role, t.rollout_path, e.status, t.created_at
                                         FROM thread_spawn_edges e JOIN threads t ON t.id=e.child_thread_id
                                         WHERE e.parent_thread_id=?""", (parent,))
                    for ident, nickname, role, rollout, edge, created in rows:
                        if ident in seen:
                            continue
                        if parent in roots and not any(start <= created <= end for start, end in self.windows.get(parent, [])):
                            continue
                        seen.add(ident)
                        pending.append(ident)
                        state, updated, started = self.child_state(rollout)
                        ended = (moment(updated) or None) if state in ("idle", "stopped") else None
                        children.append(item(ident, "codexAgent", nickname or role or "Codex subagent",
                                             "completed" if edge == "closed" else state, updated,
                                             "Parent thread " + parent, ident, started=started, ended=ended))
        except (sqlite3.Error, OSError):
            pass
        return children

    def child_state(self, rollout):
        # An open edge can belong to an idle agent. Only an actual turn event supplies working/idle.
        try:
            file = Path(rollout).resolve()
            if not any((self.codex_home / top).resolve() in file.parents for top in ("sessions", "archived_sessions")):
                return "unknown", None, None
            stat = file.stat()
            inode, offset, state, when, started = self.turns.get(file, (stat.st_ino, 0, "unknown", None, None))
            if inode != stat.st_ino or offset > stat.st_size:
                offset, state, when, started = 0, "unknown", None, None
            if stat.st_size == offset:
                return state, when, started
            with file.open("rb") as stream:
                stream.seek(offset)
                for line in stream:
                    if not line.endswith(b"\n"):
                        break
                    offset += len(line)
                    if b'"event_msg"' not in line:
                        continue
                    if not any(marker in line for marker in (b'"task_started"', b'"task_complete"', b'"turn_aborted"')):
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    next_state = {"task_started": "running", "task_complete": "idle", "turn_aborted": "stopped"}.get(
                        (row.get("payload") or {}).get("type"))
                    if row.get("type") == "event_msg" and next_state:
                        state, when = next_state, row.get("timestamp")
                        if state == "running":
                            started = moment(when) or None
            self.turns[file] = (stat.st_ino, offset, state, when, started)
            return state, when, started
        except (OSError, TypeError, ValueError):
            pass
        return "unknown", None, None

    def snapshot(self, session, log, entry):
        if not session:
            if self.session:
                self.reset(None, None)
            return []
        self.read_transcript(session, log)
        if entry.get("cwd") and os.path.isabs(entry["cwd"]):
            self.directories.add(entry["cwd"])
        if time.monotonic() >= self.refresh_at:
            jobs = self.codex_jobs()
            self.jobs = jobs + self.codex_children(jobs)
            self.agents = self.claude_agents(log)
            self.refresh_at = time.monotonic() + 3
        items = {row["id"]: dict(row) for row in [*self.tasks.values(), *self.agents, *self.jobs]
                 if row["reference"] not in self.agent_calls}
        opened = entry.get("startedAt")
        for row in items.values():
            if row["kind"] in ("claudeAgent", "shell", "listener") and row["status"] in ("running", "listening"):
                if isinstance(opened, (int, float)) and 0 < moment(row["updated"]) < opened / 1000:
                    row["status"] = "unknown"
            if row["kind"] == "listener" and row["status"] == "listening" and self.deadlines.get(row["reference"], float("inf")) < time.time():
                row["status"] = "unknown"
        if entry.get("kind") == "interactive" and entry.get("sessionId") == session:
            term = item(session, "terminal", "Claude Code", {"working": "running", "ready": "idle", "attention": "waiting"}.get(phase(entry), "unknown"),
                        None, entry.get("tmux") or "Paired terminal")
            changed = entry.get("statusUpdatedAt")
            if term["status"] == "running" and isinstance(changed, (int, float)) and changed > 0:
                term["startedAt"] = changed / 1000
            items[term["id"]] = term
        return sorted(items.values(), key=lambda row: (str(row["updated"] or ""), row["id"]), reverse=True)

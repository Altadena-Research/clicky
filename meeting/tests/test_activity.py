import datetime
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skill"))
from meeting_activity import MeetingActivity


class MeetingActivityTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name).resolve()
        self.session = str(uuid.uuid4())
        self.other = str(uuid.uuid4())
        self.log = self.folder / (self.session + ".jsonl")
        self.log.touch()
        self.codex = self.folder / "codex"
        self.codex.mkdir()
        self.tracker = MeetingActivity(self.folder / "plugin", self.codex)
        self.now = datetime.datetime.now(datetime.timezone.utc)
        self.stamp = self.now.isoformat()
        self.entry = {"kind": "interactive", "sessionId": self.session, "cwd": str(self.folder), "status": "idle"}

    def append(self, role, content, **extras):
        row = dict(sessionId=self.session, type=role, timestamp=self.stamp, cwd=str(self.folder),
                   message={"content": content})
        row.update(extras)
        with self.log.open("a") as stream:
            stream.write(json.dumps(row) + "\n")

    def launch(self, tool, params, result, call="call"):
        self.append("assistant", [{"type": "tool_use", "id": call, "name": tool, "input": params}])
        self.append("user", [{"type": "tool_result", "tool_use_id": call}], toolUseResult=result)

    def view(self):
        self.tracker.refresh_at = 0
        return {r["reference"]: r for r in self.tracker.snapshot(self.session, self.log, self.entry)}

    def test_claude_lifecycle_and_session_switch(self):
        self.launch("Monitor", {"description": "Transcript"}, {"taskId": "m1", "timeoutMs": 1800000})
        self.launch("Bash", {"description": "Test build", "command": "DO NOT DISPLAY"},
                    {"backgroundTaskId": "b1", "stdout": "PRIVATE"})
        self.append("assistant", [{"type": "tool_use", "id": "aCall", "name": "Agent",
                                   "input": {"description": "Check layout", "prompt": "PRIVATE"}}])
        self.assertEqual(self.view()["aCall"]["status"], "running")
        metadata = self.log.with_suffix("") / "subagents" / "agent-a1.meta.json"
        metadata.parent.mkdir(parents=True)
        metadata.write_text(json.dumps({"toolUseId": "aCall", "description": "Check layout", "finished": False}))
        rows = self.view()
        self.assertIn("a1", rows)
        self.assertNotIn("aCall", rows)
        self.append("user", [{"type": "tool_result", "tool_use_id": "aCall"}],
                    toolUseResult={"agentId": "a1", "isAsync": True})
        self.append("user", "<task-notification><task-id>b1</task-id><status>completed</status></task-notification>",
                    origin={"kind": "task-notification"}, sessionId=self.other)
        rows = self.view()
        self.assertEqual([rows[k]["status"] for k in (self.session, "b1", "a1", "m1")],
                         ["idle", "running", "running", "listening"])
        self.assertNotIn("PRIVATE", str(rows))
        self.assertNotIn("DO NOT DISPLAY", str(rows))
        self.append("user", "<task-notification><task-id>b1</task-id><status>failed</status></task-notification>",
                    origin={"kind": "task-notification"})
        self.launch("TaskStop", {}, {"task_id": "m1"})
        metadata.write_text(json.dumps({"toolUseId": "aCall", "finished": True}))
        rows = self.view()
        self.assertEqual([rows[k]["status"] for k in ("b1", "a1", "m1")], ["failed", "completed", "stopped"])
        self.assertEqual(self.tracker.snapshot(self.other, None, {}), [])

    def test_registered_jobs_and_scoped_descendants(self):
        slug = self.folder.name + "-" + hashlib.sha256(os.fsencode(self.folder)).hexdigest()[:16]
        registry = self.tracker.plugin_state / slug / "state.json"
        registry.parent.mkdir(parents=True)
        own = dict(sessionId=self.session, id="task-a-1", title="Codex Resume", threadId="parent", pid=os.getpid(),
                   status="running", summary="PRIVATE MEMO", createdAt=self.stamp, updatedAt=self.stamp)
        registry.write_text(json.dumps({"jobs": [own, dict(own, id="foreign", threadId="foreign", sessionId=self.other)]}))
        self.launch("Bash", {"description": "Research the design"}, {"stdout": "Codex Resume started in the background as task-a-1."})
        roll = self.codex / "sessions" / "roll.jsonl"
        roll.parent.mkdir()
        def event(name):
            with roll.open("a") as stream:
                stream.write(json.dumps({"type": "event_msg", "timestamp": self.stamp, "payload": {"type": name}}) + "\n")
        event("task_started")
        with sqlite3.connect(self.codex / "state_5.sqlite") as db:
            db.execute("create table threads(id, agent_nickname, agent_role, rollout_path, created_at)")
            db.execute("create table thread_spawn_edges(parent_thread_id,child_thread_id,status)")
            for parent, child, created in [("parent", "kid", self.now.timestamp()), ("kid", "nested", self.now.timestamp()),
                                            ("foreign", "stranger", self.now.timestamp()), ("parent", "old", 100)]:
                db.execute("insert into threads values (?,?,?,?,?)", (child, "Tester", "", str(roll), int(created)))
                db.execute("insert into thread_spawn_edges values (?,?,?)", (parent, child, "open"))
        rows = self.view()
        self.assertEqual(set(rows), {self.session, "task-a-1", "kid", "nested"})
        self.assertEqual(rows["task-a-1"]["title"], "Research the design")
        self.assertEqual(rows["kid"]["status"], "running")
        self.assertNotIn("PRIVATE", str(rows))
        event("task_complete")
        registry.write_text("{")
        self.assertEqual(self.view()["kid"]["status"], "idle")
        self.assertIn("task-a-1", self.view())
        registry.write_text(json.dumps({"jobs": [dict(own, status="failed", completedAt=self.stamp)]}))
        self.assertEqual(self.view()["task-a-1"]["status"], "failed")

    def test_expired_listener_and_partial_records(self):
        self.stamp = "2020-01-01T00:00:00Z"
        self.launch("Monitor", {}, {"taskId": "old", "timeoutMs": 1000})
        self.assertEqual(self.view()["old"]["status"], "unknown")
        line = json.dumps({"type": "assistant", "sessionId": self.session, "message": {"content": [
            {"type": "tool_use", "id": "x", "name": "Agent", "input": {"description": "Late"}}]}})
        with self.log.open("a") as stream:
            stream.write(line[:30])
        self.assertNotIn("x", self.view())
        with self.log.open("a") as stream:
            stream.write(line[30:] + "\n")
        self.assertIn("x", self.view())

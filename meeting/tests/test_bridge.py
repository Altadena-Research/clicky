import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

BRIDGE = Path(__file__).resolve().parents[1] / "skill" / "bridge.py"


class MeetingBridgeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.ipc = self.folder / "runtime"
        self.state = self.folder / "state"
        self.state.mkdir()
        self.config = self.folder / "claude"
        self.project = self.config / "projects" / "test"
        self.project.mkdir(parents=True)
        self.session = str(uuid.uuid4())
        self.other = str(uuid.uuid4())
        self.generation = "first"
        self.select_meeting()
        self.env = dict(os.environ, WISPR_MEETING_STATE_DIR=str(self.state),
                        WISPR_DATA_DIR=str(self.folder / "wispr"), CLICKY_STATE_DIR=str(self.folder / "clicky"),
                        CLICKY_RUNTIME_DIR=str(self.ipc), CLAUDE_CONFIG_DIR=str(self.config))

    def select_meeting(self, stopped=False):
        (self.state / (self.session + ".json")).write_text(json.dumps({
            "meeting_id": "fixture", "generation": self.generation, "stopped": stopped}))

    def process(self, *args):
        proc = subprocess.Popen([sys.executable, "-B", "-u", str(BRIDGE), *args],
                                env=self.env, cwd=self.folder, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def finish():
            if proc.poll() is None:
                proc.terminate()
            proc.communicate(timeout=4)
        self.addCleanup(finish)
        return proc

    def listen(self):
        proc = self.process("watch", "--session", self.session)
        for _ in range(100):
            if (self.ipc / (self.session + ".sock")).exists():
                return proc
            time.sleep(.02)
        self.fail("listener did not appear")

    def read(self, proc):
        self.assertTrue(select.select([proc.stdout], [], [], 4)[0], "event timed out")
        return json.loads(proc.stdout.readline())

    def command(self, ui, **data):
        ui.stdin.write(json.dumps(data).encode() + b"\n")
        ui.stdin.flush()

    def test_paired_history_reply_and_disconnect(self):
        listener = self.listen()
        def row(session, role, content, **extra):
            return dict(type=role, message={"content": content}, uuid=str(uuid.uuid4()),
                        timestamp="2026-01-01T00:00:00Z", sessionId=session, **extra)
        question = 'What did we decide about "A" & <B>?'
        rows = [row(self.session, "assistant", [{"type": "text", "text": "## Decision\n\n- **Amber**"}]),
                row(self.other, "assistant", [{"type": "text", "text": "wrong session"}]),
                row(self.session, "assistant", [{"type": "thinking", "thinking": "hidden"}]),
                row(self.session, "user", [{"type": "tool_result", "content": "raw transcript"}])]
        log = self.project / (self.session + ".jsonl")
        log.write_text("".join(json.dumps(r) + "\n" for r in rows))
        ui = self.process("ui")
        self.assertEqual(self.read(ui)["sessions"], [self.session])
        self.command(ui, op="select", session=self.session)
        history = self.read(ui)["messages"]
        self.assertEqual([r["text"] for r in history], ["## Decision\n\n- **Amber**"])
        self.command(ui, op="ask", session=self.other, question="wrong session")
        self.assertEqual(self.read(ui)["type"], "error")
        self.command(ui, op="ask", session=self.session, question=question)
        self.assertEqual(self.read(ui)["type"], "sent")
        self.assertEqual(self.read(ui)["messages"][-1]["text"], question)
        event = self.read(listener)
        self.assertEqual(event["question"], question)
        text = '<task-notification>\n<summary>Monitor event: "Questions typed in Clicky Meeting"</summary>\n<event>' + json.dumps(event) + '</event>\n</task-notification>'
        with log.open("a") as f:
            f.write(json.dumps(row(self.session, "user", text, origin={"kind": "task-notification"})) + "\n")
        with log.open("a") as f:
            f.write(json.dumps(row(self.session, "assistant", [{"type": "text", "text": "Answered"}])) + "\n")
        refreshed = self.read(ui)["messages"]
        self.assertEqual([m["text"] for m in refreshed].count(question), 1)
        self.assertIn("Answered", [m["text"] for m in refreshed])
        # A fresh UI can restore the previously sent question from Claude's own log.
        reopened = self.process("ui")
        self.read(reopened)
        self.command(reopened, op="select", session=self.session)
        self.assertEqual([m["text"] for m in self.read(reopened)["messages"]].count(question), 1)
        self.select_meeting(stopped=True)
        self.assertEqual(self.read(listener)["event"], "clicky_disconnected")
        self.assertEqual(listener.wait(3), 0)
        self.command(reopened, op="ask", session=self.session, question="late question")
        for _ in range(3):
            if self.read(reopened)["type"] == "error":
                break
        else:
            self.fail("expected disconnect error")

    def test_image_only_message_reaches_existing_listener_and_keeps_preview(self):
        listener = self.listen()
        # An already-running listener predates the cwd field. Recover the exact project from its live session.
        metadata = self.ipc / (self.session + ".meta")
        registration = json.loads(metadata.read_text())
        del registration["cwd"]
        metadata.write_text(json.dumps(registration))
        registry = self.config / "sessions"
        registry.mkdir()
        (registry / (str(os.getpid()) + ".json")).write_text(json.dumps({
            "pid": os.getpid(), "sessionId": self.session, "cwd": str(self.folder)}))
        ui = self.process("ui")
        self.read(ui)
        self.command(ui, op="select", session=self.session)
        folder = Path(self.read(ui)["attachmentFolder"])
        self.assertEqual(folder, self.folder.resolve() / ".clicky-attachments" / self.session)
        image = str(uuid.uuid4())
        folder.mkdir(parents=True)
        path = folder / (image + ".png")
        path.write_bytes(b"fixture")
        self.command(ui, op="ask", session=self.session, question="", images=[image])
        self.assertEqual(self.read(ui)["type"], "sent")
        view = self.read(ui)
        self.assertEqual(view["messages"][-1]["images"], [str(path)])
        self.assertNotIn(str(path), view["messages"][-1]["text"])
        self.assertEqual(view["activity"], "sent")
        self.assertIn(str(path), self.read(listener)["question"])
        self.command(ui, op="ask", session=self.session, question="", images=[str(uuid.uuid4())])
        self.assertEqual(self.read(ui)["type"], "error")
        legacy_id = str(uuid.uuid4())
        legacy = Path(self.env["CLICKY_STATE_DIR"]).resolve() / "attachments" / self.session / (legacy_id + ".png")
        legacy.parent.mkdir(parents=True)
        legacy.write_bytes(b"old fixture")
        self.command(ui, op="ask", session=self.session, question="", images=[legacy_id])
        self.assertEqual(self.read(ui)["type"], "error")
        (folder / (legacy_id + ".png")).symlink_to(legacy)
        self.command(ui, op="ask", session=self.session, question="", images=[legacy_id])
        self.assertEqual(self.read(ui)["type"], "error")
        note = "\n\n[Images attached in Clicky]\nPlease use the Read tool to view these local image files before answering:\n"
        old_event = json.dumps({"event": "clicky_question", "question": "Earlier" + note + str(legacy)})
        old_row = {"type": "user", "uuid": "old", "timestamp": "2020", "sessionId": self.session,
                   "origin": {"kind": "task-notification"}, "message": {"content":
                   '<summary>Monitor event: "Questions typed in Clicky Meeting"</summary><event>' + old_event}}
        (self.project / (self.session + ".jsonl")).write_text(json.dumps(old_row) + "\n")
        earlier = next(msg for msg in self.read(ui)["messages"] if msg["id"] == "old")
        self.assertEqual((earlier["text"], earlier["images"]), ("Earlier", [str(legacy)]))
        self.command(ui, op="stop", session=self.other)
        self.assertEqual(self.read(ui)["type"], "error")

    def test_duplicate_and_unpaired_listeners(self):
        self.listen()
        for session, error in ((self.session, "already has"), (self.other, "Start /meeting")):
            result = subprocess.run([sys.executable, str(BRIDGE), "watch", "--session", session],
                                    env=self.env, capture_output=True, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error.encode(), result.stderr)


if __name__ == "__main__":
    unittest.main()

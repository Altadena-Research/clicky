import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skill"))
from bridge import visible_message
import chat_controls
from meeting_feed import MeetingFeed

LINK = "http://aurelius-mac-2:8700/output/raw/ff0c8d99c07c"


class FeedTests(unittest.TestCase):
    def setUp(self):
        self.feed = MeetingFeed()
        self.session = str(uuid.uuid4())
        self.parent = None

    def row(self, role, content, **extras):
        ident = str(uuid.uuid4())
        row = dict(type=role, uuid=ident, parentUuid=self.parent, sessionId=self.session,
                   message={"content": content}, **extras)
        self.parent = ident
        self.feed.consume(row, None, visible_message)
        return ident

    def notice(self, task):
        self.row("user", f"<task-notification><task-id>{task}</task-id><status>completed</status></task-notification>",
                 origin={"kind": "task-notification"})

    def publish(self, tool="one"):
        self.row("assistant", [{"type": "tool_use", "name": "Bash", "id": tool,
                                "input": {"command": "python3 ~/tools/hub-output/capture.py --link notes.md"}}])

    def receipt(self, url=LINK, tool="one", failed=False):
        self.row("user", [{"type": "tool_result", "tool_use_id": tool, "is_error": failed}],
                 toolUseResult={"stdout": url + "  Research review [aurelius, main]"})

    def test_chat_routing(self):
        self.notice("listener")
        quiet = self.row("assistant", [{"type": "text", "text": "Restarted the listener."}])
        important = self.row("assistant", [{"type": "text", "text": "Restarted the listener. Approval is required."}])
        mixed = self.row("assistant", [{"type": "text", "text": "I restarted the listener. The deal closed today."}])
        user = self.row("user", "Did it restart?")
        answer = self.row("assistant", [{"type": "text", "text": "Restarted the listener."}])
        self.assertTrue(self.feed.lines[quiet]["routine"])
        for key in (important, mixed, user, answer):
            self.assertNotIn("routine", self.feed.lines[key])

    def test_concurrent_publication_stays_with_launch_and_ignores_unpublished_urls(self):
        self.notice("job-a")
        self.publish()
        first_branch = self.parent
        self.notice("job-b")
        self.publish("two")
        self.receipt(LINK + "/extra", "two")
        self.parent = first_branch
        self.receipt()
        self.assertEqual(list(self.feed.bindings), ["job-a"])
        self.assertEqual(self.feed.outputs[LINK]["title"], "Research review")
        self.row("user", "Publish another review")
        self.publish("three")
        self.receipt(tool="three", failed=True)
        self.row("assistant", [{"type": "text", "text": "[Open result for wrong](http://example.org/not-ours)"}])
        self.assertEqual(len(self.feed.outputs), 1)
        self.row("assistant", [{"type": "text", "text": f"[Open result for original-id]({LINK})"}])
        self.assertIn(LINK, self.feed.bindings["original-id"])

    def test_followup_can_publish_from_a_later_turn(self):
        self.row("user", "Follow up on “Research” (job task-abc-123, original thread abc-123).")
        self.publish()
        self.receipt()
        self.assertIn(LINK, self.feed.bindings["task-abc-123"])

    def test_review_targets_attached_client_and_sends_no_input(self):
        commands = []
        def run(command, **kwargs):
            commands.append(command)
            output = { "list-panes": "/dev/ttys015 %7 $2\n", "list-clients": "/dev/ttys012\n" }
            return SimpleNamespace(stdout=next((text for name, text in output.items() if name in command), ""), returncode=0)
        with patch.object(chat_controls, "paired_tty", return_value="/dev/ttys015"), \
             patch.object(chat_controls, "tmux_binary", return_value="/tmux"), \
             patch.object(chat_controls.subprocess, "run", side_effect=run), patch.object(chat_controls, "focus_tty") as focus:
            with self.assertRaisesRegex(ValueError, "no longer waiting"):
                chat_controls.review_terminal({"status": "idle"}, self.session)
            chat_controls.review_terminal({"status": "permission"}, self.session)
            focus.assert_called_once_with("/dev/ttys012")
            self.assertEqual(commands[-1][-5:], ["switch-client", "-c", "/dev/ttys012", "-t", "%7"])
            self.assertFalse(any("send-keys" in cmd for cmd in commands))

    def test_scoped_replay_and_partial_record(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "log"
            rows = [dict(type="assistant", sessionId=session, uuid=str(i), message={"content": text})
                    for i, (session, text) in enumerate([(self.session, "one"), ("other", "private"), (self.session, "two")])]
            p.write_text("\n".join(map(json.dumps, rows)))
            self.feed.read(p, self.session, None, visible_message)
            self.assertEqual(list(self.feed.lines), ["0"])
            with p.open("a") as f:
                f.write("\n")
            self.feed.read(p, self.session, None, visible_message)
            self.assertEqual(list(self.feed.lines), ["0", "2"])
            self.feed.read(None, self.session, None, visible_message)
            self.assertEqual(len(self.feed.lines), 2)
            self.feed.read(None, "elsewhere", None, visible_message)
            self.assertFalse(self.feed.lines)

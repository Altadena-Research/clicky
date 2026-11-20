import datetime
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skill"))
import recordings


class RecordingTests(unittest.TestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.root = Path(root.name).resolve()
        paths = patch.multiple(recordings, DATA=self.root, CURSORS=self.root / "cursors",
                               CONFIG=self.root / "claude", PREFERENCES=self.root / "prefs")
        paths.start()
        self.addCleanup(paths.stop)
        self.db = sqlite3.connect(self.root / "flow.sqlite")
        self.addCleanup(self.db.close)
        self.db.execute("CREATE TABLE Meetings (id TEXT, title TEXT, createdAt TEXT, finalized INTEGER, "
                        "endedAt TEXT, isDeleted INTEGER, isTourDemo INTEGER, importSource TEXT)")
        self.ui = self.reopen()
        self.recording = self.add_recording()
        self.session = str(uuid.uuid4())

    def reopen(self):
        model = recordings.Invitations()
        self.addCleanup(model.db.close)
        return model

    def add_recording(self, *, ended=False, local=True, age=0, demo=0, source=None):
        meeting = str(uuid.uuid4())
        now = time.time() - age
        timestamp = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat()
        self.db.execute("INSERT INTO Meetings VALUES(?,?,?,?,?,0,?,?)",
                        (meeting, "Fixture", timestamp, int(ended), timestamp if ended else None, demo, source))
        self.db.commit()
        if local:
            folder = self.root / "meetings" / meeting
            folder.mkdir(parents=True)
            (folder / "live.ndjson").touch()
            os.utime(folder / "live.ndjson", (now, now))
            os.utime(folder, (now, now))
        return meeting

    def cursor(self, session, meeting):
        recordings.CURSORS.mkdir(exist_ok=True)
        (recordings.CURSORS / (session + ".json")).write_text(json.dumps({
            "meeting_id": meeting, "generation": "fixture-generation", "stopped": False}))

    def test_detection_uses_local_active_recordings_and_dismissal_survives_restart(self):
        for options in [dict(ended=True), dict(local=False), dict(age=601), dict(demo=1), dict(source="import")]:
            self.add_recording(**options)
        self.assertEqual(list(recordings.recordings()), [self.recording])
        with patch.object(recordings, "launch_claude") as launch:
            self.assertEqual(self.ui.view([])["id"], self.recording)
            self.ui.respond("dismiss", self.recording, None, [])
            self.assertIsNone(self.reopen().view([]))
            self.assertEqual(self.add_recording(), self.reopen().view([])["id"])
            launch.assert_not_called()

    def test_open_reuses_paired_session_or_asks_which_matching_conversation(self):
        other = str(uuid.uuid4())
        self.cursor(self.session, self.recording)
        self.cursor(other, self.recording)
        with patch.object(recordings, "launch_claude") as launch:
            self.ui.respond("open", self.recording, None, [self.session, other])
            self.assertEqual(set(self.ui.view([])["choices"]), {self.session, other})
            self.ui.respond("open", self.recording, other, [self.session, other])
            self.assertIsNone(self.ui.view([other]))
            self.assertEqual(self.ui.next_selection, other)
            launch.assert_not_called()

    def test_running_unpaired_session_receives_one_request(self):
        self.cursor(self.session, self.recording)
        registry = recordings.CONFIG / "sessions"
        registry.mkdir(parents=True)
        (registry / (str(os.getpid()) + ".json")).write_text(json.dumps({
            "pid": os.getpid(), "sessionId": self.session, "name": "Existing Claude"}))
        with patch.object(recordings, "launch_claude") as launch:
            self.ui.respond("open", self.recording, None, [])
            request = recordings.read_object(recordings.CURSORS / (self.session + ".clicky-request"))
            self.assertEqual((request["meeting"], request["generation"]), (self.recording, "fixture-generation"))
            self.assertEqual(self.ui.view([])["status"], "opening")
            self.ui.respond("open", self.recording, None, [])
            self.assertIsNone(self.ui.view([self.session]))
            self.assertEqual(self.ui.next_selection, self.session)
            launch.assert_not_called()

    def test_launch_pins_id_and_avoids_duplicate_after_restart(self):
        self.ui.set_project(str(self.root))
        with patch.object(recordings, "launch_claude") as launch:
            self.ui.respond("open", self.recording, None, [])
            session, meeting, project = launch.call_args.args
            self.assertEqual((meeting, project), (self.recording, str(self.root)))
            self.assertEqual(recordings.read_object(recordings.CURSORS / (session + ".clicky-request"))["meeting"], meeting)
            self.reopen().respond("open", meeting, None, [])
            launch.assert_called_once()

    def test_stale_click_after_end_and_failed_launch_are_recoverable(self):
        with patch.object(recordings, "launch_claude", side_effect=ValueError("launch failed")):
            with self.assertRaisesRegex(ValueError, "launch failed"):
                self.ui.respond("open", self.recording, None, [])
        self.assertEqual(self.ui.view([])["status"], "new")
        self.assertFalse(list(recordings.CURSORS.glob("*.clicky-request")))
        self.db.execute("UPDATE Meetings SET finalized=1, endedAt='now' WHERE id=?", (self.recording,))
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "ended"):
            self.ui.respond("open", self.recording, None, [])
        self.assertIsNone(self.ui.view([]))

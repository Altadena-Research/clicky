import datetime
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

SKILL = Path(__file__).resolve().parents[1] / "skill"
sys.path.insert(0, str(SKILL))
import recordings

HELPER = Path(os.environ.get("CLICKY_MEETING_HELPER", Path.home() / ".claude/skills/meeting/scripts/meeting.py"))


class ResumeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.id = str(uuid.uuid4())
        self.session = str(uuid.uuid4())
        self.cursor = self.root / "state"
        self.folder = self.root / "meetings" / self.id
        self.folder.mkdir(parents=True)
        self.stop = int((time.time() - 180) * 1000)
        self.db = sqlite3.connect(self.root / "flow.sqlite")
        self.addCleanup(self.db.close)
        self.db.execute("CREATE TABLE Meetings (id,title,createdAt,finalized,endedAt,isDeleted,serverRecordingLive,latestRecordingStopSeq)")
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.db.execute("INSERT INTO Meetings VALUES(?,'fixture',?,1,?,0,1,1)", (self.id, now, self.stop))
        self.db.commit()
        self.pcm = self.folder / "mic.pcm"
        self.pcm.write_bytes(b"x")
        self.log = self.folder / "live.ndjson"
        self.append(id="old", text="Earlier fixture", timestamp="03:12")
        self.append(id="mark", marker="resumed", timestamp="8:42pm", epochMs=self.stop + 3000, segment=1)
        settings = patch.multiple(recordings, DATA=self.root, CURSORS=self.cursor,
                                  PREFERENCES=self.root / "prefs", CONFIG=self.root / "config")
        settings.start()
        self.addCleanup(settings.stop)

    def append(self, **record):
        with self.log.open("a") as file:
            file.write(json.dumps(record) + "\n")

    def test_live_flag_and_recent_local_audio_both_required(self):
        self.assertEqual(recordings.recordings()[self.id][1], 1)
        os.utime(self.pcm, (time.time() - 30,) * 2)
        self.log.touch()
        self.assertFalse(recordings.recordings())
        self.pcm.touch()
        self.db.execute("UPDATE Meetings SET serverRecordingLive=0")
        self.db.commit()
        self.assertFalse(recordings.recordings())

    def test_resumed_segment_after_dismissal_and_after_existing_pair(self):
        ui = recordings.Invitations()
        self.addCleanup(ui.db.close)
        self.assertEqual(ui.view([])["segment"], 1)
        ui.respond("dismiss", self.id, None, [], 1)
        self.assertIsNone(ui.view([]))
        self.db.execute("UPDATE Meetings SET latestRecordingStopSeq=2")
        self.db.commit()
        ui.refresh(force=True)
        self.assertEqual(ui.view([])["segment"], 2)
        with self.assertRaisesRegex(ValueError, "changed"):
            ui.respond("open", self.id, None, [], 1)
        self.cursor.mkdir()
        (self.cursor / (self.session + ".json")).write_text(json.dumps({"meeting_id": self.id, "generation": "a"}))
        ui.respond("open", self.id, self.session, [self.session], 2)
        self.db.execute("UPDATE Meetings SET latestRecordingStopSeq=3")
        self.db.commit()
        ui.refresh(force=True)
        self.assertIsNone(ui.view([self.session]))
        self.assertEqual(ui.next_selection, self.session)
        self.assertEqual(ui.db.execute("SELECT segment FROM invitations").fetchone()[0], 3)

    @unittest.skipUnless(HELPER.is_file(), "local /meeting skill required")
    def test_wispr_resume_marker_and_clock_display_preserve_new_speech(self):
        spec = importlib.util.spec_from_file_location("fixture_meeting", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        helper.DATA, helper.STATE = self.root, self.cursor
        self.assertEqual(helper.start(self.session, "active")["transcript_data"], [])
        self.append(id="new", text="After resuming", timestamp="04:13")
        self.assertEqual([r["id"] for r in helper.poll(self.session)["transcript_data"]], ["new"])
        self.assertEqual([r["id"] for r in helper.start("other", self.id)["transcript_data"]], ["new"])
        self.assertEqual([r["id"] for r in helper.snapshot(self.session)["transcript_data"]], ["old", "new"])

    @unittest.skipUnless(HELPER.is_file(), "local /meeting skill required")
    def test_same_monitor_survives_stop_and_resume(self):
        env = dict(os.environ, WISPR_DATA_DIR=str(self.root), WISPR_MEETING_STATE_DIR=str(self.cursor))
        command = [sys.executable, "-B", str(HELPER)]
        def helper(op, *args):
            out = subprocess.check_output(command + [op, "--session", self.session, *args], env=env)
            return json.loads(out)
        helper("start")
        generation = helper("status")["generation"]
        proc = subprocess.Popen(command + ["watch", "--session", self.session, "--batch-seconds", "0.1",
                                          "--follow-resumes", "--duration", "16"], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def cleanup():
            if proc.poll() is None:
                proc.terminate()
            proc.communicate(timeout=4)
        self.addCleanup(cleanup)
        self.db.execute("UPDATE Meetings SET serverRecordingLive=0")
        self.db.commit()
        self.assertEqual(json.loads(proc.stdout.readline())["event"], "meeting_ended")
        self.db.execute("UPDATE Meetings SET serverRecordingLive=1, latestRecordingStopSeq=2")
        self.db.commit()
        self.pcm.touch()
        self.append(marker="resumed", epochMs=int(time.time()*1000), segment=2)
        self.append(id="later", text="The second restart", timestamp="08:10")
        self.assertEqual(json.loads(proc.stdout.readline())["event"], "meeting_resumed")
        update = json.loads(proc.stdout.readline())
        self.assertEqual([r["id"] for r in update["transcript_data"]], ["later"])
        self.assertEqual(helper("status")["generation"], generation)
        helper("stop")
        self.assertEqual(json.loads(proc.stdout.readline())["event"], "stopped")

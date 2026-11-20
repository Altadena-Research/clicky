"""Local Wispr capture-state signals shared by Clicky and the /meeting reader."""
import datetime
import time
import uuid


def activity_columns(columns):
    return ", ".join(field if field in columns else "0 AS " + field
                     for field in ("serverRecordingLive", "latestRecordingStopSeq"))


def timestamp_seconds(value):
    try:
        number = float(value)
        return number / 1000 if number > 100_000_000_000 else number
    except (ValueError, TypeError):
        try:
            return datetime.datetime.fromisoformat(value.replace("Z", "+00:00").replace(" +", "+")).timestamp()
        except (ValueError, TypeError, AttributeError, OverflowError):
            return None


def resumed_segment(data, row):
    # Wispr retains finalized and endedAt across resumes. Its server flag can also
    # describe another machine. Require a recent local PCM write after the last stop.
    if row["serverRecordingLive"] != 1:
        return 0
    ended = timestamp_seconds(row["endedAt"])
    if ended is None:
        return 0
    folder = data / "meetings" / str(uuid.UUID(row["id"]))
    now = time.time()
    for channel in ("mic.pcm", "system.pcm"):
        try:
            channel_stat = (folder / channel).stat()
        except OSError:
            continue
        if channel_stat.st_size and ended + 1 < channel_stat.st_mtime and -1 <= now - channel_stat.st_mtime <= 12:
            return int(row["latestRecordingStopSeq"] or max(1, int(ended * 1000)))
    return 0

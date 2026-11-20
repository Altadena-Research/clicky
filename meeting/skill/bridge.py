"""Local transport between one explicitly paired Claude conversation and Clicky."""
from __future__ import annotations

import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import selectors
import socket
import stat
import sys
import uuid

from recordings import Invitations

ROOT = Path(os.environ.get("CLICKY_RUNTIME_DIR", f"/tmp/clicky-meeting-{os.getuid()}"))
PROJECTS = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "projects"
STATE = Path(os.environ.get("WISPR_MEETING_STATE_DIR", str(Path.home() / ".local/state/wispr-meeting")))
MAX_QUESTION = 4000


def runtime():
    ROOT.mkdir(mode=0o700, exist_ok=True)
    info = ROOT.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Clicky's runtime directory must be private to this account.")
    return ROOT


def emit(obj):
    print(json.dumps(obj, ensure_ascii=True), flush=True)


def session_id(value):
    return str(uuid.UUID(value))


def meeting_key(session):
    try:
        value = json.loads((STATE / (session + ".json")).read_bytes())
        if not value.get("stopped"):
            return (value["meeting_id"], value["generation"])
    except (FileNotFoundError, ValueError, KeyError):
        pass
    return None


def read_line(connection):
    with connection.makefile("rb") as stream:
        data = stream.readline(32769)
    if len(data) > 32768 or not data.endswith(b"\n"):
        raise ValueError("Incomplete question.")
    return json.loads(data)


def sockets():
    paired = []
    for path in runtime().glob("*.sock"):
        if has_listener(path.stem):
            registration = session_info(path.stem)
            if registration and ("meeting_id" not in registration or
                                 meeting_key(path.stem) == (registration["meeting_id"], registration["generation"])):
                paired.append(path.stem)
    return sorted(paired)


def has_listener(session):
    try:
        with (ROOT / (session + ".lock")).open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    except FileNotFoundError:
        pass
    return False


def watch(session):
    selected = meeting_key(session)
    if selected is None:
        raise ValueError("Start /meeting in this Claude conversation first.")
    folder = runtime()
    project_name = Path.cwd().name
    address = folder / (session + ".sock")
    metadata = folder / (session + ".meta")
    with (folder / (session + ".lock")).open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("This conversation already has a Clicky listener.")
        address.unlink(missing_ok=True)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            os.chdir(folder)  # Darwin limits socket addresses to 103 bytes, including the path.
            server.bind(address.name)
            info = {"project": project_name, "projects": str(PROJECTS.resolve()),
                    "meeting_id": selected[0], "generation": selected[1]}
            metadata.write_text(json.dumps(info))
            server.listen(4)
            server.settimeout(1)
            try:
                while meeting_key(session) == selected:
                    try:
                        client, _ = server.accept()
                    except socket.timeout:
                        continue
                    with client:
                        client.settimeout(2)
                        try:
                            data = read_line(client)
                            question = data["question"].strip()
                            if not question or len(question) > MAX_QUESTION:
                                raise ValueError("Enter a question of 1–4000 characters.")
                            if meeting_key(session) != selected:
                                raise ValueError("The selected meeting changed.")
                            identifier = str(uuid.uuid4())
                            emit({"event": "clicky_question", "id": identifier, "question": question})
                            result = {"ok": True, "id": identifier}
                        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
                            result = {"error": str(error)}
                        with contextlib.suppress(OSError):
                            client.sendall(json.dumps(result).encode() + b"\n")
                emit({"event": "clicky_disconnected"})
            finally:
                address.unlink(missing_ok=True)
                metadata.unlink(missing_ok=True)


def send(session, question):
    address = runtime() / (session + ".sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        os.chdir(address.parent)
        client.connect(address.name)
        client.sendall(json.dumps({"question": question}).encode() + b"\n")
        return read_line(client)


def session_info(session):
    try:
        return json.loads((ROOT / (session + ".meta")).read_bytes())
    except (OSError, ValueError):
        return {}


def transcript_path(session):
    # Lookup uses only the paired UUID, including after a project directory rename.
    projects = Path(session_info(session).get("projects", PROJECTS))
    return next(projects.glob("*/" + session + ".jsonl"), None)


def visible_message(row):
    role = row.get("type")
    if role not in ("user", "assistant") or row.get("isMeta") or row.get("isSidechain"):
        return None
    content = row.get("message", {}).get("content")
    identifier = row.get("uuid") or row.get("timestamp")
    if role == "user" and row.get("origin", {}).get("kind") == "task-notification":
        tag = '<summary>Monitor event: "Questions typed in Clicky Meeting"</summary>'
        if not isinstance(content, str) or tag not in content or "<event>" not in content:
            return None
        try:
            event, _ = json.JSONDecoder().raw_decode(content.partition("<event>")[2].lstrip())
            if event.get("event") != "clicky_question":
                return None
            content = event["question"]
            identifier = event.get("id") or identifier
        except (ValueError, KeyError, AttributeError):
            return None
    elif role == "user" and isinstance(content, list):
        if not all(isinstance(part, dict) and part.get("type") == "text" for part in content):
            return None
        content = "\n".join(part.get("text", "") for part in content)
    if role == "assistant" and isinstance(content, list):
        content = "\n\n".join(block["text"] for block in content
                              if isinstance(block, dict) and block.get("type") == "text" and block.get("text"))
    if not isinstance(content, str) or not content.strip():
        return None
    if role == "user" and content.lstrip().startswith(("<", "/")):
        return None
    return {"id": identifier, "role": role,
            "text": content.strip(), "time": row.get("timestamp", "")}


def recent_messages(path, session):
    messages = []
    if path is None:
        return messages
    with path.open("rb") as stream:
        # Keep refresh bounded even for sessions with large embedded tool results.
        end = stream.seek(0, os.SEEK_END)
        start = max(0, end - 2 * 1024 * 1024)
        stream.seek(max(0, start - 1))
        if start and stream.read(1) != b"\n":
            stream.readline()
        for line in stream:
            if not line.endswith(b"\n"):
                break
            try:
                row = json.loads(line)
                if row.get("sessionId") != session:
                    continue
                message = visible_message(row)
                if message and message["id"]:
                    messages.append(message)
            except (ValueError, TypeError, AttributeError, KeyError):
                continue
    return messages[-40:]


def ui():
    # A single helper process sleeps between file checks. Only the explicitly
    # selected Claude transcript is opened. Question text travels over a pipe.
    invitations = Invitations()
    selected = None
    log = None
    fingerprint = None
    previous = None
    messages = []
    questions = {}
    with selectors.DefaultSelector() as selector:
        selector.register(sys.stdin, selectors.EVENT_READ)
        while True:
            available = sockets()
            invitation = invitations.view(available)
            if invitations.next_selection:
                selected, log, fingerprint, messages = invitations.next_selection, None, None, []
                invitations.next_selection = None
                emit({"type": "opened", "session": selected})
            if selected in available and log is None:
                log = transcript_path(selected)
            if selected not in available:
                log, fingerprint = None, None
            if log:
                try:
                    info = log.stat()
                    stamp = (info.st_ino, info.st_size, info.st_mtime_ns)
                    if fingerprint != stamp:
                        messages = recent_messages(log, selected)
                        fingerprint = stamp
                except FileNotFoundError:
                    log = None
                    fingerprint = None
            by_id = {item["id"]: item for item in questions.get(selected, [])}
            by_id.update((item["id"], item) for item in messages)
            combined = sorted(by_id.values(), key=lambda item: item["time"])
            labels = {session: session_info(session).get("project", "") for session in available}
            state = {"type": "view", "sessions": available, "labels": labels, "selected": selected,
                     "connected": selected in available, "messages": combined[-40:], "invitation": invitation,
                     "project": invitations.project, "detectionError": invitations.problem}
            if state != previous:
                emit(state)
                previous = state
            if not selector.select(1):
                continue
            line = sys.stdin.readline()
            if not line:
                return
            try:
                request = json.loads(line)
                if request["op"] == "project":
                    invitations.set_project(request["path"])
                    continue
                if request["op"] in ("open", "dismiss"):
                    invitations.respond(request["op"], request["meeting"], request.get("session"), sockets())
                    continue
                requested = session_id(request["session"])
                if request["op"] == "select":
                    if requested not in sockets():
                        raise ValueError("This conversation is no longer paired.")
                    selected, log, fingerprint, messages = requested, transcript_path(requested), None, []
                elif request["op"] == "ask":
                    if requested != selected or requested not in sockets():
                        raise ValueError("The selected conversation disconnected.")
                    question = request["question"].strip()
                    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
                    result = send(selected, question)
                    if not result.get("ok"):
                        raise ValueError(result.get("error", "Delivery failed."))
                    if result.get("id"):
                        history = questions.setdefault(selected, [])
                        history.append({"id": result["id"], "role": "user", "text": question, "time": timestamp})
                        del history[:-40]
                    emit({"type": "sent", "session": selected})
            except (ValueError, OSError, KeyError) as error:
                emit({"type": "error", "message": str(error)})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["watch", "ui"])
    parser.add_argument("--session", type=session_id)
    args = parser.parse_args()
    try:
        if args.command == "ui":
            ui()
        elif args.session:
            watch(args.session)
        else:
            parser.error("watch requires --session")
    except (OSError, ValueError) as error:
        sys.exit(str(error))

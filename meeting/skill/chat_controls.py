"""Activity and turn interruption for the exact locally paired Claude terminal."""
import os
from pathlib import Path
import re
import shutil
import subprocess

from recordings import CONFIG, read_object


def tmux_binary():
    return shutil.which("tmux", path=os.pathsep.join([os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin"]))


class SessionActivity:
    def __init__(self):
        self.paths = {}

    def entry(self, session):
        if not session:
            return {}
        cached = self.paths.get(session)
        candidates = [cached] if cached else (CONFIG / "sessions").glob("*.json")
        for path in candidates:
            entry = read_object(path)
            if entry.get("sessionId") == session and path.stem == str(entry.get("pid")):
                try:
                    os.kill(int(entry["pid"]), 0)
                except (OSError, ValueError):
                    continue
                self.paths[session] = path
                return entry
        self.paths.pop(session, None)
        return {}


def phase(entry):
    status = entry.get("status")
    if status == "busy":
        return "working"
    if status in ("waiting", "requires_action", "needs_input", "permission"):
        return "attention"
    if status in ("idle", "shell"):
        return "ready"
    return "unknown"


def paired_tty(entry, session):
    if entry.get("sessionId") != session or entry.get("kind") != "interactive" or entry.get("entrypoint") != "cli":
        raise ValueError("Open the terminal paired with this meeting.")
    pid = int(entry["pid"])
    info = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "uid=,pgid=,tpgid=,tty=,lstart=,comm="],
                          text=True, capture_output=True, env=dict(os.environ, TZ="UTC", LC_ALL="C")).stdout.split(None, 9)
    if (len(info) != 10 or info[0] != str(os.getuid()) or info[1] != info[2]
            or not re.fullmatch(r"ttys[0-9]+", info[3]) or
            " ".join(info[4:9]) != " ".join(str(entry.get("procStart", "")).split())):
        raise ValueError("Claude no longer owns the selected terminal. Check the original meeting tab.")
    executable = Path(info[9].strip())
    if executable.name != "claude" and not (executable.parent.name == "versions" and "claude" in executable.parts):
        raise ValueError("The selected terminal is no longer running Claude Code.")
    return "/dev/" + info[3]


def tmux_servers(binary, session, entry):
    servers = [[binary, "-L", "clicky-" + session]]
    if entry.get("tmux"):
        servers.append([binary])
    return servers


def review_terminal(entry, session):
    if phase(entry) != "attention":
        raise ValueError("Claude is no longer waiting for input.")
    tty = paired_tty(entry, session)
    tmux = tmux_binary()
    if tmux:
        for server in tmux_servers(tmux, session, entry):
            panes = subprocess.run(server + ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id} #{session_id}"],
                                   capture_output=True, text=True, timeout=3)
            pane = next((line.split() for line in panes.stdout.splitlines()
                         if len(line.split()) == 3 and line.split()[0] == tty), None)
            if not pane:
                continue
            clients = subprocess.run(server + ["list-clients", "-t", pane[2], "-F", "#{client_tty}"],
                                     capture_output=True, text=True, timeout=3)
            client = next((t for t in clients.stdout.splitlines() if re.fullmatch(r"/dev/ttys[0-9]+", t)), None)
            if not client:
                raise ValueError("The paired tmux session has no attached terminal. Open its tmux client to review.")
            focus_tty(client)
            if paired_tty(entry, session) == tty:
                subprocess.run(server + ["switch-client", "-c", client, "-t", pane[1]], check=True,
                               capture_output=True, timeout=3)
            return
    focus_tty(tty)


def focus_tty(tty):
    script = Path(__file__).with_name("review_terminal.applescript")
    result = subprocess.run(["/usr/bin/osascript", str(script), tty], capture_output=True, timeout=20)
    if result.returncode:
        raise ValueError("Couldn’t focus the paired tab. Open the original Claude terminal to review.")


def interrupt(entry, session):
    tty = paired_tty(entry, session)
    pid = int(entry["pid"])
    tmux = tmux_binary()
    if tmux:
        for server in tmux_servers(tmux, session, entry):
            result = subprocess.run(server + ["list-panes", "-a", "-F", "#{pane_id} #{pane_tty}"],
                                    text=True, capture_output=True, timeout=3)
            for line in result.stdout.splitlines():
                pane, _, device = line.partition(" ")
                if device == tty and re.fullmatch(r"%[0-9]+", pane):
                    result = subprocess.run(server + ["send-keys", "-t", pane, "Escape"], capture_output=True, timeout=3)
                    if result.returncode:
                        raise ValueError("The Claude pane closed before the stop was delivered.")
                    return
    # iTerm exposes individual sessions by tty. Never type into the front window
    # or signal the process itself (SIGINT can terminate the entire Claude CLI).
    parents = pid
    for _ in range(12):
        row = subprocess.run(["/bin/ps", "-p", str(parents), "-o", "ppid=,comm="],
                             capture_output=True, text=True).stdout.strip().split(None, 1)
        if len(row) != 2 or row[0] == "0":
            break
        if Path(row[1]).name == "iTerm2":
            script = Path(__file__).with_name("stop_iterm.applescript")
            result = subprocess.run(["/usr/bin/osascript", str(script), tty, str(pid), str(entry["procStart"]),
                                     str(CONFIG / "sessions" / (str(pid) + ".json")), session],
                                    capture_output=True, timeout=15)
            if result.returncode:
                raise ValueError("Stop couldn’t reach the iTerm tab. Press Esc in the paired Claude terminal.")
            return
        parents = int(row[0])
    raise ValueError("Press Esc in the paired Claude terminal. Clicky can send Stop to iTerm2 and tmux sessions.")

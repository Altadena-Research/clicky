"""Incremental, session-scoped chat history and receipts from the Aurelius publisher."""
from __future__ import annotations

import json
import re

HUB = "http://aurelius-mac-2:8700/output"
REPORT = re.escape(HUB) + r"/raw/[0-9a-f]{12}"
RECEIPT = re.compile(r"^(" + REPORT + r")(?:[ \t]+(.{1,240}))?[ \t]*$", re.M)
BIND = re.compile(r"\[Open result for ([\w.-]+)\]\((" + REPORT + r")\)")
FOLLOW_UP = re.compile(r"Follow up on “[^\n]*?” \(job ([\w.-]+)(?:, original thread [\w.-]+)?\)\.")
FINAL_NOTICE = re.compile(r"<status>(?:completed|failed|stopped|killed|cancelled|canceled)</status>")
TASK = re.compile(r"<task-id>([\w.-]+)</task-id>")
PUBLISH = re.compile(r"(?:^|[\s/'\"])capture\.py\s+--link(?:\s|$)")
STATUS_MARKER = "[[meeting-status]]"
NO_ADVICE = re.compile(r"\bnothing (?:new )?to add(?: here| yet| on this)?[.!]?$", re.I)
RENEWAL = re.compile(r"\b(?:listener|monitor|watcher)\b", re.I)
RENEWED = re.compile(r"\b(?:restarted|renewed|re-armed|reattached)\b", re.I)
IMPORTANT = re.compile(r"https?://|\n\n|[?!]|\b(?:approve|approval|blocked|failed|error|decision|recommend|you (?:should|need)|results? (?:are|ready)|couldn.t|unable)\b", re.I)


def routine(text):
    marked = text.startswith(STATUS_MARKER)
    if marked:
        text = text[len(STATUS_MARKER):].strip()
    if len(text) > 260 or IMPORTANT.search(text):
        return False
    if marked or NO_ADVICE.search(text):
        return True
    if not (RENEWAL.search(text) and RENEWED.search(text)):
        return False
    clauses = re.split(r"(?<=[.!])\s+|;\s*|,?\s+(?:but|and)\s+(?=the |I |we |you |they )", text, flags=re.I)
    return all(RENEWAL.search(part) or re.fullmatch(r"Run `?/meeting stop`? to end it[.]?", part, re.I)
               for part in clauses)



class MeetingFeed:
    def __init__(self):
        self.identity = None
        self.offset = 0
        self.context = {}
        self.publishing = {}
        self.lines = {}
        self.outputs = {}
        self.bindings = {}

    def read(self, path, session, folder, visible_message):
        if not path:
            if self.identity and self.identity[0] != session:
                self.__init__()
            return
        try:
            info = path.stat()
            identity = session, path, info.st_dev, info.st_ino, folder
            if identity != self.identity or info.st_size < self.offset:
                self.__init__()
                self.identity = identity
            if info.st_size == self.offset:
                return
            with path.open("rb") as stream:
                stream.seek(self.offset)
                for line in stream:
                    if not line.endswith(b"\n"):
                        break
                    self.offset += len(line)
                    try:
                        row = json.loads(line)
                        if row.get("sessionId") == session and not row.get("isSidechain"):
                            self.consume(row, folder, visible_message)
                    except (ValueError, TypeError, KeyError, AttributeError):
                        continue
        except OSError:
            return

    def consume(self, row, folder, visible_message):
        role, uid = row.get("type"), row.get("uuid")
        content = (row.get("message") or {}).get("content")
        automatic, owner = self.context.get(row.get("parentUuid"), (False, None))
        message = visible_message(row, folder)
        if role == "user":
            if (row.get("origin") or {}).get("kind") == "task-notification":
                automatic = not bool(message)
                match = TASK.search(content) if isinstance(content, str) else None
                owner = match[1] if automatic and match and FINAL_NOTICE.search(content) else None
            elif not isinstance(content, list) or any(b.get("type") != "tool_result" for b in content if isinstance(b, dict)):
                automatic, owner = False, None
        if role == "user" and message:
            follow = FOLLOW_UP.search(message["text"])
            if follow:
                owner = follow[1]
        if uid:
            self.context[uid] = (automatic, owner)
        for block in content if isinstance(content, list) else []:
            if not isinstance(block, dict):
                continue
            if role == "assistant" and block.get("type") == "tool_use" and block.get("name") == "Bash":
                if PUBLISH.search((block.get("input") or {}).get("command", "")):
                    self.publishing[block["id"]] = owner
            if role == "user" and block.get("type") == "tool_result" and block.get("tool_use_id") in self.publishing:
                job = self.publishing.pop(block["tool_use_id"])
                result = row.get("toolUseResult")
                if block.get("is_error") or not isinstance(result, dict) or result.get("interrupted"):
                    continue
                for url, label in RECEIPT.findall(result.get("stdout") or ""):
                    title = re.sub(r"\s+\[[^\]]+\]\s*$", "", label).strip()
                    prior = self.outputs.pop(url, {})
                    self.outputs[url] = {"url": url, "title": title or prior.get("title") or "Published report"}
                    if job:
                        self.bindings.setdefault(job, {})[url] = None
        if message:
            if role == "assistant":
                text = message["text"]
                for job, url in BIND.findall(text):
                    if url in self.outputs:
                        self.bindings.setdefault(job, {})[url] = None
                if automatic and routine(text):
                    message["routine"] = True
                if text.startswith(STATUS_MARKER):
                    message["text"] = text[len(STATUS_MARKER):].strip() or "No meeting update."
            self.lines[message["id"]] = message

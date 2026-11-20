# Clicky Meeting for Mac

Clicky floats beside your other windows. When Wispr Notetaker starts a local recording, the character offers to open its Claude Code conversation. Choose **Open** to pair, or **Not now** to dismiss the current recording segment across app restarts. When Wispr resumes under the same ID, an existing paired chat follows it. Otherwise Clicky offers to open the resumed segment. Ordinary Wispr dictation does not trigger an invitation.

**Open** reuses a running Claude conversation following that exact recording. If several conversations match, choose one by name and session ID. With no match, Clicky opens iTerm2 (or Terminal), starts Claude Code in your selected project and runs your existing `/meeting use <recording-id>` skill. Claude’s normal permissions apply. Use **Choose Meeting Project…** in Clicky’s menu bar menu to choose where new conversations start.

Click the character to expand or collapse the chat. Drag the character to move it. Drag a panel edge or the lower-right grip to resize the conversation. Clicky remembers the size. When collapsed, new assistant replies appear briefly beside the character. When capture ends, Claude can answer follow-up questions from the same chat. The transcript watcher waits for that recording to resume, checking only recording metadata while idle. A resumed chat waits for speech after Wispr’s resume marker and keeps the earlier conversation available.

## Install

Requires macOS 14.2 or later, Apple’s Command Line Tools, Claude Code with the Monitor tool, Wispr Flow Notetaker and the local Wispr `/meeting` skill. Run these commands from the repository root. Apply the patch and create the skill link once.

```sh
install -m 644 meeting/skill/wispr_activity.py "$HOME/.claude/skills/meeting/scripts/wispr_activity.py"
patch -d "$HOME/.claude/skills/meeting" -p1 < meeting/wispr-skill.patch
ln -s "$PWD/meeting/skill" "$HOME/.claude/skills/clicky-meeting"
./meeting/build.sh
open "$HOME/Applications/Clicky Meeting.app"
```

The patch targets the Wispr skill with `scripts/meeting.py`. For checkouts with the earlier pairing-only patch, reverse that version of the patch before applying the current one. The current patch adds pairing and resume handling to the transcript watcher. Both the skill and Clicky recognize a resume when Wispr reports live recording and the local mic or system capture file has been written since the previous stop. They inspect file metadata only for detection. Rebuilding the app also refreshes its bundled helpers. If the checkout moves, update the skill link. Leave Clicky running to receive invitations.

## Existing terminal conversations

To use a particular terminal chat, run `/meeting` there and choose **Open** in Clicky. For a listener that was already running when you installed the patch, run `/clicky-meeting` once in that conversation. This is also the manual recovery if a question listener times out. Use `/meeting stop` to disconnect that conversation from the recording.

Clicky checks the local Wispr database and recording directory metadata every three seconds. Opening a meeting lets your Claude skill load its transcript. Questions travel over a private local socket to a Monitor in the selected conversation. The panel displays up to 40 visible messages from the last 2 MiB of that session’s Claude log. The Claude session’s normal context and retention settings apply.

## Tests

```sh
python3 -B -m unittest discover -s meeting/tests
./meeting/build.sh --test-resize
```

The Python tests use synthetic Wispr recordings, cursor files and Claude logs. With the patched skill installed they also check that one watcher follows a stop and resume, and that the initial resumed snapshot excludes speech from the earlier segment. The AppKit test exercises the corner grip, minimum size and saved dimensions in an isolated panel.

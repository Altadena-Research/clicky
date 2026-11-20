# Clicky Meeting for Mac

Clicky floats beside your other windows. When Wispr Notetaker starts a local recording, the character offers to open its Claude Code conversation. Choose **Open** to pair, or **Not now** to dismiss that recording across app restarts. Ordinary Wispr dictation does not trigger an invitation.

**Open** reuses a running Claude conversation following that exact recording. If several conversations match, choose one by name and session ID. With no match, Clicky opens iTerm2 (or Terminal), starts Claude Code in your selected project and runs your existing `/meeting use <recording-id>` skill. Claude’s normal permissions apply. Use **Choose Meeting Project…** in Clicky’s menu bar menu to choose where new conversations start.

Click the character to expand or collapse the chat. Drag the character to move it. Drag a panel edge or the lower-right grip to resize the conversation. Clicky remembers the size. When collapsed, new assistant replies appear briefly beside the character. When the recording ends, the transcript listener finishes and the paired chat remains available for follow-up questions while Claude is running.

## Install

Requires macOS 14.2 or later, Apple’s Command Line Tools, Claude Code with the Monitor tool, Wispr Flow Notetaker and the local Wispr `/meeting` skill. Run these commands from the repository root. Apply the patch and create the skill link once.

```sh
patch -d "$HOME/.claude/skills/meeting" -p1 < meeting/wispr-skill.patch
ln -s "$PWD/meeting/skill" "$HOME/.claude/skills/clicky-meeting"
./meeting/build.sh
open "$HOME/Applications/Clicky Meeting.app"
```

The patch targets the Wispr skill with `scripts/meeting.py`. It adds a local pairing request to the existing transcript watcher and uses Wispr’s end marker for finished calls. Rebuilding the app also refreshes its bundled helpers. If the checkout moves, update the skill link. Leave Clicky running to receive invitations.

## Existing terminal conversations

To use a particular terminal chat, run `/meeting` there and choose **Open** in Clicky. For a listener that was already running when you installed the patch, run `/clicky-meeting` once in that conversation. This is also the manual recovery if a question listener times out. Use `/meeting stop` to disconnect that conversation from the recording.

Clicky checks the local Wispr database and recording directory metadata every three seconds. Opening a meeting lets your Claude skill load its transcript. Questions travel over a private local socket to a Monitor in the selected conversation. The panel displays up to 40 visible messages from the last 2 MiB of that session’s Claude log. The Claude session’s normal context and retention settings apply.

## Tests

```sh
python3 -B -m unittest discover -s meeting/tests
./meeting/build.sh --test-resize
```

The Python tests use synthetic Wispr recordings, cursor files and Claude logs. The AppKit test exercises the corner grip, minimum size and saved dimensions in an isolated panel.

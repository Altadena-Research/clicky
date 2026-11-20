# Clicky Meeting for Mac

Click the blue character to open the recent conversation from the Claude Code session running your Wispr Flow `/meeting` skill. Drag it to move it. New assistant replies appear briefly beside the collapsed character. The expanded panel renders headings, bullets, emphasis, and code. Escape or the close button collapses it.

## Run the test build

Requires macOS 14.2+, Apple's Command Line Tools, Claude Code with the Monitor tool, and the existing local Wispr `/meeting` skill. From the repository root:

```sh
./meeting/build.sh
mkdir -p ~/.claude/skills
ln -s "$PWD/meeting/skill" ~/.claude/skills/clicky-meeting
open "$HOME/Applications/Clicky Meeting.app"
```

Create the skill link once. Rebuilding the app also refreshes its bundled helper. If the checkout moves, update the link.

1. Start Wispr Notetaker. Run `/meeting` in your Claude Code terminal as usual.
2. Run `/clicky-meeting` in **that same conversation**. Once the listener is running, click the character. When several conversations are paired, select one under **Sessions**.
3. Ask something in the terminal. Follow up in the character. Replies from either place appear in both. Claude can refresh the meeting transcript before answering.
4. Use `/meeting stop` to disconnect from that meeting. The character stays available. The menu-bar icon can reopen the panel or quit the app.

The companion reads the recent end of the selected session's local Claude JSONL log for display (up to 40 visible messages from its last 2 MiB). Claude itself answers using its ongoing session context. Tool output and hidden reasoning are excluded from the panel. Questions travel over a user-private local socket to a Monitor in the live conversation. The paired session continues to use its normal Claude permissions, processing and history. A changed meeting selection closes its pairing.

Pairing is manual in this build. If Claude reports that the question monitor timed out without renewing, run `/clicky-meeting` again in the same conversation. The original voice companion and its Xcode project remain available separately.

## Tests

```sh
python3 -B -m unittest discover -s meeting/tests
```

The transport tests use temporary directories and synthetic Claude logs. They cover session isolation, recovering questions from history, duplicate listeners and disconnection.

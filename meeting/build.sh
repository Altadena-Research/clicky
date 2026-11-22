#!/bin/bash
# Build the meeting-only companion with the macOS Command Line Tools.
set -eo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$HOME/Applications/Clicky Meeting.app}"
builddir="$(mktemp -d)"
trap 'rm -r "$builddir"' EXIT
# Some upgraded Command Line Tools leave the old SwiftBridging module map
# beside its identical replacement. Hide the duplicate for this build only.
swift_include="$(xcode-select -p)/usr/include/swift"
compiler_options=()
if [[ -f "$swift_include/bridging.modulemap" && -f "$swift_include/module.modulemap" ]] &&
   diff -q <(sed -n '/^module /,$p' "$swift_include/module.modulemap") \
           <(sed -n '/^module /,$p' "$swift_include/bridging.modulemap") >/dev/null; then
    touch "$builddir/empty.modulemap"
    /usr/bin/python3 - "$swift_include/module.modulemap" "$builddir" <<'PYMAP'
import json, pathlib, sys
work = pathlib.Path(sys.argv[2])
(work / "modules.json").write_text(json.dumps({
    "version": 0, "roots": [{"type": "file", "name": sys.argv[1],
                             "external-contents": str(work / "empty.modulemap")}]}))
PYMAP
    compiler_options=(-vfsoverlay "$builddir/modules.json" -Xcc -ivfsoverlay -Xcc "$builddir/modules.json")
fi
if [[ "${1:-}" == "--test-composer" ]]; then
    swiftc "${compiler_options[@]}" -DTEST_COMPOSER -parse-as-library -target "$(uname -m)-apple-macosx14.2" \
        meeting/{MeetingApp,PanelResize,ChatImages,ReplyText,MeetingActivity,MeetingQueue}.swift meeting/tests/test_composer.swift -o "$builddir/test-composer"
    "$builddir/test-composer"
    exit
fi
if [[ "${1:-}" == "--test-replies" ]]; then
    swiftc "${compiler_options[@]}" -parse-as-library -target "$(uname -m)-apple-macosx14.2" \
        meeting/ReplyText.swift meeting/tests/test_replies.swift -o "$builddir/test-replies"
    "$builddir/test-replies" "${@:2}"
    exit
fi
if [[ "${1:-}" == "--test-resize" ]]; then
    swiftc "${compiler_options[@]}" -parse-as-library meeting/PanelResize.swift meeting/tests/test_resize.swift -o "$builddir/test-resize"
    "$builddir/test-resize"
    exit
fi
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
swiftc "${compiler_options[@]}" -parse-as-library -target "$(uname -m)-apple-macosx14.2" -O \
    meeting/{MeetingApp,PanelResize,ChatImages,ReplyText,MeetingActivity,MeetingQueue}.swift -o "$builddir/ClickyMeeting"
install -m 755 "$builddir/ClickyMeeting" "$destination/Contents/MacOS/ClickyMeeting"
install -m 644 meeting/Info.plist "$destination/Contents/Info.plist"
install -m 644 meeting/Resources/Marcus.png "$destination/Contents/Resources/Marcus.png"
install -m 644 meeting/skill/{bridge,recordings,wispr_activity,chat_controls,meeting_activity,meeting_feed}.py meeting/skill/{stop_iterm,review_terminal}.applescript "$destination/Contents/Resources/"
codesign --force --sign - "$destination"
printf 'Built %s\n' "$destination"

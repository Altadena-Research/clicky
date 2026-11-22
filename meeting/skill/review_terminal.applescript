on run argv
    set targetTTY to item 1 of argv
    if application id "com.googlecode.iterm2" is running then
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then
                            select t
                            select s
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
    end if
    if application id "com.apple.Terminal" is running then
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
    end if
    error "No matching terminal tab"
end run

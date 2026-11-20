on run argv
    set expectedTTY to item 1 of argv
    set targetPID to item 2 of argv
    set expectedStart to words of item 3 of argv
    set registryPath to item 4 of argv
    set sessionID to item 5 of argv
    using terms from application "iTerm2"
        tell application id "com.googlecode.iterm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if tty of terminalSession is expectedTTY then
                            -- Recheck after any macOS Automation permission prompt.
                            set processInfo to words of (do shell script "/usr/bin/env TZ=UTC LC_ALL=C /bin/ps -p " & quoted form of targetPID & " -o pgid=,tpgid=,tty=,lstart=")
                            if (item 1 of processInfo is not item 2 of processInfo) or ("/dev/" & item 3 of processInfo is not expectedTTY) or (items 4 thru -1 of processInfo is not expectedStart) then error "Session changed"
                            set sessionNow to do shell script "/usr/bin/plutil -extract sessionId raw -o - " & quoted form of registryPath
                            set phaseNow to do shell script "/usr/bin/plutil -extract status raw -o - " & quoted form of registryPath
                            if sessionNow is not sessionID or phaseNow is not in {"busy", "waiting", "requires_action", "needs_input", "permission"} then error "Turn ended"
                            tell terminalSession to write text (ASCII character 27) without newline
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
    end using terms from
    error "Claude terminal unavailable"
end run

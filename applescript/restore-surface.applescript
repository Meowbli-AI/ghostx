on run argv
    if (count of argv) is not 2 then return "invalid"
    set expectedID to item 1 of argv
    set resumeCommand to item 2 of argv

    tell application "Ghostty"
        repeat with terminalRef in terminals
            if (id of terminalRef as text) is expectedID then
                input text resumeCommand to terminalRef
                delay 0.05
                send key "enter" to terminalRef
                return "restored"
            end if
        end repeat
    end tell

    return "missing"
end run


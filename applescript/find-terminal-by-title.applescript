on run argv
    if (count of argv) is not 1 then return ""
    set expectedTitle to item 1 of argv

    tell application "Ghostty"
        repeat with terminalRef in terminals
            if (name of terminalRef as text) is expectedTitle then
                return id of terminalRef as text
            end if
        end repeat
    end tell

    return ""
end run


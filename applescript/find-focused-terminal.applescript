on run argv
    if (count of argv) is not 1 then return ""
    set expectedDirectory to item 1 of argv

    with timeout of 1 second
        tell application "Ghostty"
            if (count of windows) is 0 then return ""

            set terminalRef to focused terminal of selected tab of front window
            if terminalRef is missing value then return ""
            if (working directory of terminalRef as text) is not expectedDirectory then return ""

            return id of terminalRef as text
        end tell
    end timeout
end run

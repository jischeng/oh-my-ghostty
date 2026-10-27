#!/bin/sh
# OpenSSH invokes this outside the terminal byte stream. Never log the answer.
exec /usr/bin/osascript - "$1" <<'APPLESCRIPT'
on run argv
    set promptText to item 1 of argv
    try
        if promptText contains "yes/no" then
            set response to display dialog promptText with title "OMG SSH" buttons {"Cancel", "No", "Yes"} default button "No"
            if button returned of response is "Yes" then return "yes"
            return "no"
        end if
        set response to display dialog promptText with title "OMG SSH" default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue"
        return text returned of response
    on error number -128
        error number 1
    end try
end run
APPLESCRIPT

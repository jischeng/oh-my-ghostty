# OMG-only best-effort VT scrollback replay, sourced by local interactive shells.
# The host supplies a validated owner-only file for a restored Surface UUID.
if [ -n "${OH_MY_GHOSTTY_RESTORE_SCROLLBACK_FILE:-}" ]; then
    _omg_restore_file=$OH_MY_GHOSTTY_RESTORE_SCROLLBACK_FILE
    unset OH_MY_GHOSTTY_RESTORE_SCROLLBACK_FILE
    if [ -f "$_omg_restore_file" ] && [ -r "$_omg_restore_file" ]; then
        /bin/cat -- "$_omg_restore_file" 2>/dev/null || true
        /usr/bin/printf '\033[0;2m\r\n  ──────  Session restored · %s  ──────\033[0m\r\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')"
        /bin/rm -f -- "$_omg_restore_file" 2>/dev/null || true
    fi
    unset _omg_restore_file
fi

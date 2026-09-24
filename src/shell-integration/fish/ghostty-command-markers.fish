# Shared by local Ghostty integration and OMG's temporary +ssh bootstrap.
# Prompt events are status-isolated by Fish. Never print before calling the
# original fish_prompt: Starship reads both $status and $pipestatus there.
function __ghostty_command_markers_init
    if set -q __ghostty_command_markers_initialized
        return
    end
    set -g __ghostty_command_markers_initialized 1

    functions -q fish_prompt; or return
    functions -c fish_prompt __ghostty_original_history_prompt
    function fish_prompt
        __ghostty_original_history_prompt
        builtin printf '\e]133;B\a'
    end

    function __ghostty_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
        if test "$__ghostty_prompt_state" != prompt-start
            builtin printf '\e]133;D\a'
        end
        set -g __ghostty_prompt_state prompt-start
        builtin printf '%b' "$__ghostty_prompt_start_mark"
    end

    function __ghostty_mark_output_start --on-event fish_preexec
        set -g __ghostty_prompt_state pre-exec
        if set -q argv[1]
            set -l encoded (string escape --style=url -- "$argv[1]")
            if test (string length -- "$encoded") -le 16384
                builtin printf '\e]133;C;cmdline_url=%s\a' "$encoded"
                return
            end
        end
        builtin printf '\e]133;C\a'
    end

    function __ghostty_mark_output_end --on-event fish_postexec
        set -l result $status
        set -g __ghostty_prompt_state post-exec
        builtin printf '\e]133;D;%s\a' "$result"
    end
end

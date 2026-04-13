#!/usr/bin/env bash
# Boo shell integration for bash.
# Source this file from ~/.bashrc or ~/.bash_profile:
#   source ~/.boo/shell-integration/boo.bash
#
# Requires bash 3.2+ (macOS default).

# Guard against double-sourcing and non-interactive shells.
[[ -z "$PS1" ]] && return
[[ -n "$BOO_SHELL_INTEGRATION" ]] && return
export BOO_SHELL_INTEGRATION=bash

# Command tracking via OSC 2 (SET_TITLE) with BOO_CMD: prefix.
# Boo intercepts these before they reach the title bar.
# Format: ESC ] 2 ; BOO_CMD:<action>;<data> BEL
# Actions: cmd_start (data = command string), cmd_end (data = exit code)
__boo_osc() {
    printf '\033]2;BOO_CMD:%s\a' "$1"
}

__boo_preexec() {
    __boo_osc "cmd_start;$1"
}

__boo_precmd() {
    local code=$?
    __boo_osc "cmd_end;$code"
    return $code
}

# Wire into bash-preexec if available, otherwise use DEBUG trap + PROMPT_COMMAND.
if declare -f __bp_install >/dev/null 2>&1; then
    # bash-preexec is installed
    precmd_functions+=(__boo_precmd)
    preexec_functions+=(__boo_preexec)
else
    # Fallback: DEBUG trap fires before each command; PROMPT_COMMAND fires before each prompt.
    __boo_last_cmd=""
    __boo_debug_trap() {
        local cmd
        cmd=$(history 1 | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')
        if [[ "$cmd" != "$__boo_last_cmd" && -n "$cmd" ]]; then
            __boo_last_cmd="$cmd"
            __boo_preexec "$cmd"
        fi
    }
    trap '__boo_debug_trap' DEBUG

    # Prepend to PROMPT_COMMAND without clobbering existing value.
    if [[ -z "$PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="__boo_precmd"
    else
        PROMPT_COMMAND="__boo_precmd; $PROMPT_COMMAND"
    fi
fi

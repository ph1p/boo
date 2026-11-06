#!/usr/bin/env bash
# Boo shell integration for bash.
# Source this file from ~/.bashrc or ~/.bash_profile:
#   source ~/.boo/shell-integration/boo.bash
#
# Requires bash 3.2+ (macOS default).

# Guard against double-sourcing, non-interactive shells, and non-Boo terminals.
[[ -z "$PS1" ]] && return
[[ -n "$BOO_SHELL_INTEGRATION" ]] && return
[[ -z "$BOO_TERM" ]] && return
export BOO_SHELL_INTEGRATION=bash
# `boo` (agents, run, send, inbox, status) for this shell and the agents it starts.
# Checked again before each prompt: rc files that run later may rebuild PATH, and
# on a case-insensitive disk the app's own `Boo` binary would answer to `boo`.
__boo_path() {
    case "$PATH" in
    "$HOME/.boo/bin:"*) ;;
    *) export PATH="$HOME/.boo/bin:${PATH//$HOME\/.boo\/bin:/}" ;;
    esac
}
__boo_path
_BOO_INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Command tracking via OSC 2 (SET_TITLE) with BOO_CMD: prefix.
# Boo intercepts these before they reach the title bar.
# Format: ESC ] 2 ; BOO_CMD:<action>;<data> BEL
# Actions: cmd_start (data = command string), cmd_end (data = exit code)
__boo_osc() {
    printf '\033]2;BOO_CMD:%s\a' "$1"
}

_BOO_AGENT_CMDS="claude codex opencode aider"
_BOO_LAST_WAS_AGENT=0

__boo_preexec() {
    local cmd
    cmd="${1%% *}"
    cmd="${cmd##*/}"  # basename
    if [[ " $_BOO_AGENT_CMDS " == *" $cmd "* ]]; then
        _BOO_LAST_WAS_AGENT=1
    else
        _BOO_LAST_WAS_AGENT=0
    fi
    __boo_osc "cmd_start;$1"
}

__boo_precmd() {
    local code=$?
    __boo_osc "cmd_end;$code"
    __boo_path
    if [[ "$_BOO_LAST_WAS_AGENT" == "1" && -n "$BOO_SOCK" && -n "$BOO_PANE_ID" ]]; then
        _BOO_LAST_WAS_AGENT=0
        python3 -c "import socket,json,os;s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(2);s.connect('$BOO_SOCK');s.sendall(json.dumps({'cmd':'agent_idle','pane_id':'$BOO_PANE_ID'}).encode()+b'\n');s.recv(64);s.close()" 2>/dev/null &
    fi
    return $code
}

# A plain `tmux` (new session or attach) can open as Boo tabs and splits:
# tmux control mode (-CC). Settings › Terminal picks always, ask or never.
# Inside tmux, with -C/-CC already given, or for any other subcommand it is
# the usual tmux.
tmux() {
    local arg mode answer
    if [[ -n "$TMUX" ]]; then command tmux "$@"; return; fi
    for arg in "$@"; do
        case "$arg" in -C | -CC) command tmux "$@"; return ;; esac
    done
    case "$1" in
    "" | new | new-session | attach | attach-session | a | at) ;;
    *) command tmux "$@"; return ;;
    esac
    mode=$(command boo tmux mode 2>/dev/null)
    if [[ "$mode" == "ask" ]]; then
        printf 'Open tmux as Boo tabs and splits? [Y]es [n]o [a]lways ne[v]er: '
        read -r answer || return 130
        case "$answer" in
        "" | y | Y | yes) mode=always ;;
        a | A | always) command boo tmux mode always >/dev/null 2>&1; mode=always ;;
        v | V | never) command boo tmux mode never >/dev/null 2>&1; mode=never ;;
        *) mode=never ;;
        esac
    fi
    if [[ "$mode" == "always" ]]; then
        command tmux -CC "$@"
    else
        command tmux "$@"
    fi
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

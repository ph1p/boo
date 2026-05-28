# Boo shell integration for zsh.
# Source this file from ~/.zshrc:
#   source ~/.boo/shell-integration/boo.zsh

# Guard against double-sourcing, non-interactive shells, and non-Boo terminals.
[[ -o interactive ]] || return
[[ -n "$BOO_SHELL_INTEGRATION" ]] && return
[[ -z "$BOO_TERM" ]] && return
export BOO_SHELL_INTEGRATION=zsh

# Capture integration dir at source time (expands correctly for sourced files).
_BOO_INTEGRATION_DIR="${${(%):-%x}:h}"

# Command tracking via OSC 2 (SET_TITLE) with BOO_CMD: prefix.
# Boo intercepts these before they reach the title bar.
__boo_osc() {
    printf '\033]2;BOO_CMD:%s\a' "$1"
}

_BOO_AGENT_CMDS=(claude codex opencode aider)
_BOO_LAST_WAS_AGENT=0

__boo_preexec() {
    local cmd="${1%% *}"
    cmd="${cmd:t}"  # basename
    if (( ${_BOO_AGENT_CMDS[(Ie)$cmd]} )); then
        _BOO_LAST_WAS_AGENT=1
    else
        _BOO_LAST_WAS_AGENT=0
    fi
    __boo_osc "cmd_start;$1"
}

__boo_precmd() {
    local code=$?
    __boo_osc "cmd_end;$code"
    if (( _BOO_LAST_WAS_AGENT )) && [[ -n "$BOO_SOCK" && -n "$BOO_PANE_ID" ]]; then
        _BOO_LAST_WAS_AGENT=0
        python3 -c "import socket,json,os;s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(2);s.connect('$BOO_SOCK');s.sendall(json.dumps({'cmd':'agent_idle','pane_id':'$BOO_PANE_ID'}).encode()+b'\n');s.recv(64);s.close()" 2>/dev/null &!
    fi
}

# Append to zsh hook arrays without replacing existing hooks.
autoload -Uz add-zsh-hook
add-zsh-hook preexec __boo_preexec
add-zsh-hook precmd __boo_precmd

# Boo shell integration for zsh.
# Source this file from ~/.zshrc:
#   source ~/.boo/shell-integration/boo.zsh

# Guard against double-sourcing, non-interactive shells, and non-Boo terminals.
[[ -o interactive ]] || return
[[ -n "$BOO_SHELL_INTEGRATION" ]] && return
[[ -z "$BOO_TERM" ]] && return
export BOO_SHELL_INTEGRATION=zsh
# `boo` (agents, run, send, inbox, status) for this shell and the agents it starts.
# Checked again before each prompt: rc files that run later may rebuild PATH, and
# on a case-insensitive disk the app's own `Boo` binary would answer to `boo`.
__boo_path() {
    [[ "$PATH" == "$HOME/.boo/bin:"* ]] || export PATH="$HOME/.boo/bin:${PATH//$HOME\/.boo\/bin:/}"
}
__boo_path

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
    __boo_path
    if (( _BOO_LAST_WAS_AGENT )) && [[ -n "$BOO_SOCK" && -n "$BOO_PANE_ID" ]]; then
        _BOO_LAST_WAS_AGENT=0
        python3 -c "import socket,json,os;s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(2);s.connect('$BOO_SOCK');s.sendall(json.dumps({'cmd':'agent_idle','pane_id':'$BOO_PANE_ID'}).encode()+b'\n');s.recv(64);s.close()" 2>/dev/null &!
    fi
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

# Append to zsh hook arrays without replacing existing hooks.
autoload -Uz add-zsh-hook
add-zsh-hook preexec __boo_preexec
add-zsh-hook precmd __boo_precmd

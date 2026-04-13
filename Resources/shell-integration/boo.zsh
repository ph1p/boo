# Boo shell integration for zsh.
# Source this file from ~/.zshrc:
#   source ~/.boo/shell-integration/boo.zsh

# Guard against double-sourcing and non-interactive shells.
[[ -o interactive ]] || return
[[ -n "$BOO_SHELL_INTEGRATION" ]] && return
export BOO_SHELL_INTEGRATION=zsh

# Command tracking via OSC 2 (SET_TITLE) with BOO_CMD: prefix.
# Boo intercepts these before they reach the title bar.
__boo_osc() {
    printf '\033]2;BOO_CMD:%s\a' "$1"
}

__boo_preexec() {
    __boo_osc "cmd_start;$1"
}

__boo_precmd() {
    local code=$?
    __boo_osc "cmd_end;$code"
}

# Append to zsh hook arrays without replacing existing hooks.
autoload -Uz add-zsh-hook
add-zsh-hook preexec __boo_preexec
add-zsh-hook precmd __boo_precmd

# Boo shell integration for fish.
# Source this file from ~/.config/fish/config.fish:
#   source ~/.boo/shell-integration/boo.fish
#
# Or install it as a conf.d snippet:
#   ln -s ~/.boo/shell-integration/boo.fish ~/.config/fish/conf.d/boo.fish

# Guard against double-sourcing.
if set -q BOO_SHELL_INTEGRATION
    return
end
set -gx BOO_SHELL_INTEGRATION fish
# `boo` (agents, run, send, inbox, status) for this shell and the agents it starts.
# Checked again before each prompt: config that runs later may rebuild PATH, and
# on a case-insensitive disk the app's own `Boo` binary would answer to `boo`.
function __boo_path --on-event fish_prompt
    test "$PATH[1]" = $HOME/.boo/bin; or set -gx PATH $HOME/.boo/bin (string match -v -- $HOME/.boo/bin $PATH)
end
__boo_path

set -g _BOO_AGENT_CMDS claude codex opencode aider
set -g _BOO_LAST_WAS_AGENT 0

function __boo_osc
    printf '\033]2;BOO_CMD:%s\a' $argv[1]
end

function __boo_preexec --on-event fish_preexec
    set -l cmd (string split ' ' -- $argv[1])[1]
    set -l base (basename $cmd)
    if contains -- $base $_BOO_AGENT_CMDS
        set -g _BOO_LAST_WAS_AGENT 1
    else
        set -g _BOO_LAST_WAS_AGENT 0
    end
    __boo_osc "cmd_start;$argv[1]"
end

function __boo_precmd --on-event fish_postexec
    __boo_osc "cmd_end;$status"
    if test "$_BOO_LAST_WAS_AGENT" = "1" -a -n "$BOO_SOCK" -a -n "$BOO_PANE_ID"
        set -g _BOO_LAST_WAS_AGENT 0
        python3 -c "import socket,json,os;s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(2);s.connect('$BOO_SOCK');s.sendall(json.dumps({'cmd':'agent_idle','pane_id':'$BOO_PANE_ID'}).encode()+b'\n');s.recv(64);s.close()" 2>/dev/null &
    end
end

# A plain `tmux` (new session or attach) can open as Boo tabs and splits:
# tmux control mode (-CC). Settings › Terminal picks always, ask or never.
# Inside tmux, with -C/-CC already given, or for any other subcommand it is
# the usual tmux.
function tmux --wraps tmux
    if test -n "$TMUX"; or contains -- -C $argv; or contains -- -CC $argv
        command tmux $argv
        return
    end
    switch "$argv[1]"
        case '' new new-session attach attach-session a at
        case '*'
            command tmux $argv
            return
    end
    set -l mode (command boo tmux mode 2>/dev/null)
    if test "$mode" = ask
        read -l -P 'Open tmux as Boo tabs and splits? [Y]es [n]o [a]lways ne[v]er: ' answer; or return 130
        switch "$answer"
            case '' y Y yes
                set mode always
            case a A always
                command boo tmux mode always >/dev/null 2>&1
                set mode always
            case v V never
                command boo tmux mode never >/dev/null 2>&1
                set mode never
            case '*'
                set mode never
        end
    end
    if test "$mode" = always
        command tmux -CC $argv
    else
        command tmux $argv
    end
end

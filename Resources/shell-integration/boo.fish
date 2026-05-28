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

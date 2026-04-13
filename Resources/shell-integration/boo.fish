# Boo shell integration for fish.
# Source this file from ~/.config/fish/config.fish:
#   source ~/.boo/shell-integration/boo.fish
#
# Or install it as a conf.d snippet:
#   ln -s ~/.boo/shell-integration/boo.fish ~/.config/fish/conf.d/boo.fish

# Guard against double-sourcing.
if set -q BOO_SHELL_INTEGRATION
    exit
end
set -gx BOO_SHELL_INTEGRATION fish

function __boo_osc
    printf '\033]2;BOO_CMD:%s\a' $argv[1]
end

function __boo_preexec --on-event fish_preexec
    __boo_osc "cmd_start;$argv[1]"
end

function __boo_precmd --on-event fish_postexec
    __boo_osc "cmd_end;$status"
end

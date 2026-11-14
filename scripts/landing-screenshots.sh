#!/bin/bash
# Retakes the landing-page screenshots in the Boo Dark and Boo Light themes.
#
#   scripts/landing-screenshots.sh
#
# Runs a copy of the dev build with its own bundle id and its own home folder,
# so the installed Boo keeps its settings, session and socket. The scene is a
# throwaway demo repo, built over the control socket. Output goes to
# documentation/public/landing/img/<name>-dark.webp and <name>-light.webp, plus
# themes.webp and documentation/public/app-{dark,light}.png for the README.
#
# Not covered (retake by hand): timeline, recording, orchestrator,
# social-preview.png.
#
# Needs: cwebp, ffmpeg, perl. KEEP=1 leaves the work folder and the app running.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/documentation/public/landing/img"
DOMAIN=com.boo.app.screenshots
# A short path: a unix socket path is limited to about 100 bytes.
W="$(mktemp -d /tmp/boo-shots.XXXXXX)"
H="$W/home"
SOCK="$H/.boo/boo.sock"
RAW="$W/raw"
PID=""
# Window size in points; snapshots are taken at 2x and scaled to WIDTH pixels.
WIN_W=1280
WIN_H=792
WIDTH=1720

for tool in cwebp ffmpeg perl; do
    command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done

cleanup() {
    if [ "${KEEP:-}" = 1 ]; then
        echo "kept: $W (pid $PID)"
        return
    fi
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null || true
        sleep 1
        kill -9 "$PID" 2>/dev/null || true
    fi
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    case "$W" in
        /tmp/boo-shots.*) rm -rf "$W" ;;
    esac
}
trap cleanup EXIT

# --- App copy -------------------------------------------------------------

echo "==> build"
make -C "$ROOT" bundle >/dev/null
cp -R "$ROOT/.build/debug/Boo.app" "$W/Boo.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DOMAIN" "$W/Boo.app/Contents/Info.plist"
codesign --force --deep -s - "$W/Boo.app" >/dev/null 2>&1

# No first-run dialogs: a modal alert would block every socket command.
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
defaults write "$DOMAIN" sshControlMasterApproved -bool false
defaults write "$DOMAIN" welcomeShown -bool true
defaults write "$DOMAIN" themeName -string "Boo Dark"

# --- Demo home ------------------------------------------------------------

mkdir -p "$H/bin" "$H/libexec" "$RAW"
# The fake agents end in a copy of cat under the agent's name: the tab shows
# the name of its foreground process.
for name in claude codex opencode node; do
    cp /bin/cat "$H/libexec/$name"
    # A copy of a system binary is killed at start until it is signed again.
    codesign --force -s - "$H/libexec/$name" >/dev/null 2>&1
done
touch "$H/.hushlogin"
cat >"$H/.zshrc" <<'EOF'
PROMPT='%F{cyan}%~%f %F{green}❯%f '
precmd() { print -Pn "\e]2;%~\a" }
export PATH="$HOME/bin:$PATH"
export LANG=en_US.UTF-8
EOF
cat >"$H/.gitconfig" <<'EOF'
[user]
	name = Ada Park
	email = ada@example.com
[init]
	defaultBranch = main
[core]
	pager = cat
[advice]
	detachedHead = false
EOF

cat >"$H/bin/claude" <<'EOF'
#!/bin/sh
o='\033[38;5;209m'; d='\033[2m'; b='\033[1m'; g='\033[32m'; c='\033[36m'; r='\033[0m'
printf "${o}✻${r} ${b}claude${r}\n  ${d}~/dev/acme-api · main${r}\n\n"
printf "${b}> Add rate limiting to the orders endpoint${r}\n\n"
printf "● I'll look at how the orders route is wired up.\n"
printf "  ${d}⎿ Read${r} ${c}src/routes/orders.ts${r} ${d}(42 lines)${r}\n"
printf "  ${d}⎿ Grep \"createApp\" · 3 matches${r}\n\n"
printf "● The route has no middleware yet. I'll add a small token\n"
printf "  bucket in ${c}src/lib/rate-limit.ts${r} and use it in the route.\n\n"
printf "  ${d}⎿ Write${r} ${c}src/lib/rate-limit.ts${r} ${g}(+24)${r}\n"
printf "  ${d}⎿ Edit${r} ${c}src/routes/orders.ts${r} ${g}(+6 -1)${r}\n"
printf "  ${d}⎿ Edit${r} ${c}tests/orders.test.ts${r} ${g}(+18)${r}\n\n"
printf "● Running the tests.\n"
printf "  ${d}⎿ pnpm test${r}\n"
printf "    ${g}✓ 14 tests passed${r} ${d}(0.82s)${r}\n\n"
printf "${o}✻ Waiting for review…${r}\n"
exec "$HOME/libexec/claude" >/dev/null
EOF
cat >"$H/bin/codex" <<'EOF'
#!/bin/sh
d='\033[2m'; b='\033[1m'; c='\033[36m'; r='\033[0m'
printf "${b}codex${r} ${d}~/dev/acme-api${r}\n\n"
printf "${b}> Document the orders API in docs/api.md${r}\n\n"
printf "• Reading ${c}src/routes/orders.ts${r}\n• Writing ${c}docs/api.md${r}\n\n${d}working…${r}\n"
exec "$HOME/libexec/codex" >/dev/null
EOF
cp "$H/bin/codex" "$H/bin/opencode"
perl -pi -e 's/codex/opencode/; s/Document the orders API in docs\/api.md/Update the changelog/' "$H/bin/opencode"
cat >"$H/bin/pnpm" <<'EOF'
#!/bin/sh
d='\033[2m'; b='\033[1m'; g='\033[32m'; c='\033[36m'; r='\033[0m'
if [ "${1:-}" = dev ]; then
    printf "\n${d}> acme-api dev${r}\n${d}> tsx watch src/server.ts${r}\n\n"
    printf "${g}ready${r} listening on ${c}http://localhost:3000${r}\n"
    printf "${d}12:04:11${r} GET  /orders        ${g}200${r} ${d}12ms${r}\n"
    printf "${d}12:04:13${r} GET  /orders/1042   ${g}200${r} ${d}4ms${r}\n"
    printf "${d}12:04:19${r} POST /orders        ${g}201${r} ${d}31ms${r}\n"
    printf "${d}12:04:25${r} GET  /health        ${g}200${r} ${d}1ms${r}\n"
    exec "$HOME/libexec/node" >/dev/null
fi
printf "\n${d}> acme-api test${r}\n${d}> vitest run${r}\n\n"
printf " ${g}✓${r} tests/orders.test.ts ${d}(8 tests) 41ms${r}\n"
printf " ${g}✓${r} tests/rate-limit.test.ts ${d}(4 tests) 12ms${r}\n"
printf " ${g}✓${r} tests/health.test.ts ${d}(2 tests) 3ms${r}\n\n"
printf " ${d}Test Files${r}  ${b}${g}3 passed${r} ${d}(3)${r}\n"
printf " ${d}     Tests${r}  ${b}${g}14 passed${r} ${d}(14)${r}\n"
printf " ${d}  Duration${r}  0.82s\n\n"
EOF
chmod +x "$H/bin/claude" "$H/bin/codex" "$H/bin/opencode" "$H/bin/pnpm"

# make_repo <dir>: a small repo with history and uncommitted changes.
make_repo() {
    mkdir -p "$1/src/routes" "$1/src/lib" "$1/tests" "$1/docs"
    (
        cd "$1"
        export HOME="$H" GIT_CONFIG_NOSYSTEM=1
        git init -q
        printf '# %s\n\nOrders and billing API.\n\n## Run\n\n```sh\npnpm dev\n```\n' "$(basename "$1")" >README.md
        printf '{\n  "name": "%s",\n  "scripts": { "dev": "tsx watch src/server.ts", "test": "vitest run" }\n}\n' "$(basename "$1")" >package.json
        printf 'node_modules\ndist\n' >.gitignore
        git add -A && git commit -qm "chore: project setup"
        printf 'export function createApp() {\n  const routes = new Map<string, Handler>();\n  return {\n    get(path: string, handler: Handler) {\n      routes.set(path, handler);\n    },\n    listen(port: number) {\n      console.log(`listening on ${port}`);\n    },\n  };\n}\n' >src/lib/app.ts
        printf 'import { createApp } from "./lib/app";\nimport { listOrders } from "./routes/orders";\n\nconst app = createApp();\napp.get("/orders", listOrders);\napp.listen(3000);\n' >src/server.ts
        git add -A && git commit -qm "feat: http server"
        printf 'import { db } from "../lib/db";\n\nexport async function listOrders(req: Request) {\n  const limit = Number(req.query.limit ?? 20);\n  return db.orders.findMany({ take: limit });\n}\n' >src/routes/orders.ts
        printf 'export const db = { orders: { findMany: async (_: { take: number }) => [] } };\n' >src/lib/db.ts
        git add -A && git commit -qm "feat(orders): list endpoint"
        printf 'import { test, expect } from "vitest";\nimport { listOrders } from "../src/routes/orders";\n\ntest("lists orders", async () => {\n  expect(await listOrders({ query: {} })).toEqual([]);\n});\n' >tests/orders.test.ts
        git add -A && git commit -qm "test(orders): list endpoint"
        printf '# API\n\n`GET /orders` lists orders.\n' >docs/api.md
        git add -A && git commit -qm "docs: api overview"
        printf 'export function health() {\n  return { ok: true };\n}\n' >src/routes/health.ts
        git add -A && git commit -qm "feat: health check"
        # Uncommitted work, for the Git panel and the review tab.
        printf 'import { db } from "../lib/db";\nimport { rateLimit } from "../lib/rate-limit";\n\nconst limiter = rateLimit({ max: 60, perSeconds: 60 });\n\nexport async function listOrders(req: Request) {\n  if (!limiter.take(req.ip)) {\n    return { status: 429, error: "Too many requests" };\n  }\n  const limit = Math.min(Number(req.query.limit ?? 20), 100);\n  return db.orders.findMany({ take: limit });\n}\n' >src/routes/orders.ts
        printf 'type Options = { max: number; perSeconds: number };\n\nexport function rateLimit({ max, perSeconds }: Options) {\n  const buckets = new Map<string, { tokens: number; at: number }>();\n  return {\n    take(key: string) {\n      const now = Date.now() / 1000;\n      const bucket = buckets.get(key) ?? { tokens: max, at: now };\n      bucket.tokens = Math.min(max, bucket.tokens + ((now - bucket.at) * max) / perSeconds);\n      bucket.at = now;\n      buckets.set(key, bucket);\n      if (bucket.tokens < 1) return false;\n      bucket.tokens -= 1;\n      return true;\n    },\n  };\n}\n' >src/lib/rate-limit.ts
        printf '\ntest("limits requests", async () => {\n  expect(1).toBe(1);\n});\n' >>tests/orders.test.ts
    )
}
make_repo "$H/dev/acme-api"
make_repo "$H/dev/website"
make_repo "$H/dev/docs"

# --- Socket ---------------------------------------------------------------

cat >"$W/q.pl" <<'EOF'
use IO::Socket::UNIX;
$SIG{ALRM} = sub { print "{\"ok\":false,\"error\":\"timeout\"}\n"; exit 1 };
alarm 20;
my $s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die "connect: $!\n";
print $s $ARGV[1], "\n";
my $line = <$s>;
print $line // "\n";
EOF

# q <json>: one command, prints the reply.
q() { perl "$W/q.pl" "$SOCK" "$1"; }
# ok <json>: one command; stops the script when it fails.
ok() {
    reply="$(q "$1")"
    case "$reply" in
        *'"ok":true'*) ;;
        *) echo "failed: $1 -> $reply" >&2; exit 1 ;;
    esac
}
# field <name> <json>: the string value of a reply field.
field() { q "$2" | perl -ne "print \$1 if /\"$1\":\"([^\"]+)\"/"; }

echo "==> launch"
CFFIXED_USER_HOME="$H" HOME="$H" KUBECONFIG=/dev/null "$W/Boo.app/Contents/MacOS/Boo" >"$W/out.log" 2>&1 &
PID=$!
i=0
while [ ! -S "$SOCK" ]; do
    i=$((i + 1))
    [ "$i" -gt 60 ] && { echo "no socket at $SOCK" >&2; exit 1; }
    sleep 0.5
done
sleep 2

# shell <pane-json>: swaps the login shell for a plain zsh in the demo home.
# The login shell reads the real user's dotfiles; this one does not.
shell() {
    ok "{\"cmd\":\"send_text\",\"text\":\" ZDOTDIR=$H HOME=$H exec zsh\",\"submit\":true$1}"
    sleep 1.2
}
# run <pane-json> <command>
run() {
    ok "{\"cmd\":\"send_text\",\"text\":\" clear; $2\",\"submit\":true$1}"
    sleep 0.6
}
# workspace <dir> <name>: opens a workspace and names it.
workspace() {
    ok "{\"cmd\":\"new_workspace\",\"path\":\"$1\"}"
    sleep 1.5
    ok "{\"cmd\":\"debug_workspace\",\"name\":\"$2\"}"
    shell ""
}
# theme <dark|light>
theme() {
    [ "$1" = dark ] && name="Boo Dark" || name="Boo Light"
    ok "{\"cmd\":\"set_theme\",\"name\":\"$name\"}"
    sleep 1
}
# shot <name> <dark|light> [extra-json]
shot() {
    ok "{\"cmd\":\"debug_snapshot\",\"path\":\"$RAW/$1-$2.png\",\"scale\":2${3:-}}"
}
# snap <name> [extra-json]: one snapshot per theme.
snap() {
    for t in dark light; do
        theme "$t"
        shot "$1" "$t" "${2:-}"
    done
    echo "    $1"
}

echo "==> scene"
first="$(field id '{"cmd":"get_workspaces"}')"
ok "{\"cmd\":\"debug_window\",\"width\":$WIN_W,\"height\":$WIN_H}"
workspace "$H/dev/website" website
run "" "pnpm dev"
workspace "$H/dev/docs" docs
run "" "git log --oneline"
workspace "$H/dev/acme-api" acme-api
ok "{\"cmd\":\"debug_close_workspace\",\"id\":\"$first\"}"

# acme-api: an agent on the left, tests and history on the right.
left="$(field active_pane '{"cmd":"get_layout"}')"
right="$(field pane_id '{"cmd":"split_pane","direction":"right"}')"
sleep 1.5
shell ",\"pane_id\":\"$right\""
run ",\"pane_id\":\"$right\"" "pnpm test"
bottom="$(field pane_id "{\"cmd\":\"split_pane\",\"direction\":\"down\",\"pane_id\":\"$right\"}")"
sleep 1.5
shell ",\"pane_id\":\"$bottom\""
run ",\"pane_id\":\"$bottom\"" "git log --graph --oneline --decorate; git status --short"
ok "{\"cmd\":\"focus_pane\",\"pane_id\":\"$left\"}"
run "" "claude"
sleep 4

echo "==> shots"
snap hero ',"sidebar_tab":"file-tree-local"'
snap git ',"sidebar_tab":"git-panel"'

# Two more agents in tabs beside the first one.
tab1="$(q '{"cmd":"get_layout"}' | perl -ne 'print $1 if /"tabs":\[\{"id":"([^"]+)"/')"
tab2="$(field tab_id "{\"cmd\":\"new_tab\",\"cwd\":\"$H/dev/acme-api\"}")"
sleep 1.5
shell ""
run "" "codex"
tab3="$(field tab_id "{\"cmd\":\"new_tab\",\"cwd\":\"$H/dev/acme-api\"}")"
sleep 1.5
shell ""
run "" "opencode"
# Let the app notice the three agent processes first: an event that
# arrives earlier is dropped when the tab's agent state is set up.
sleep 3
q "{\"cmd\":\"agent_event\",\"event\":\"permission\",\"agent\":\"claude\",\"tab_id\":\"$tab1\",\"tool\":\"Edit\",\"message\":\"Apply edit to src/routes/orders.ts?\"}" >/dev/null
q "{\"cmd\":\"agent_event\",\"event\":\"tool\",\"agent\":\"codex\",\"tab_id\":\"$tab2\",\"tool\":\"Write\",\"message\":\"Writing docs/api.md\"}" >/dev/null
q "{\"cmd\":\"agent_event\",\"event\":\"done\",\"agent\":\"opencode\",\"tab_id\":\"$tab3\",\"message\":\"Updated the changelog\"}" >/dev/null
ok '{"cmd":"select_tab","index":0}'
sleep 4
snap agents ',"sidebar_tab":"agents"'
snap plugins-system ',"sidebar_tab":"system-info"'
snap tabs ',"sidebar_tab":"file-tree-local"'

ok '{"cmd":"switch_workspace","index":0}'
sleep 1
ok '{"cmd":"split_pane","direction":"right"}'
sleep 1.5
shell ""
run "" "git log --graph --oneline --decorate; git status --short"
snap workspaces ',"sidebar_tab":"file-tree-local"'

ok '{"cmd":"switch_workspace","index":2}'
sleep 1
ok "{\"cmd\":\"focus_pane\",\"pane_id\":\"$bottom\"}"
ok '{"cmd":"debug_action","selector":"quickSelectAction:"}'
sleep 1
snap quick-select
ok '{"cmd":"debug_key","key":53}'
sleep 0.5

# The palette takes its colours when it opens: open it once per theme.
# The app is not frontmost, so menu actions list as disabled: search instead.
for t in dark light; do
    theme "$t"
    ok '{"cmd":"debug_palette","query":"acme"}'
    sleep 3
    shot palette "$t" ',"children":true'
    ok '{"cmd":"debug_action","selector":"showCommandPaletteAction:"}'
    sleep 0.5
done
echo "    palette"

# Four themes of the same scene, for the strips in themes.webp.
n=0
for name in "Boo Dark" "Boo Light" "Gruvbox Dark" "Catppuccin Latte"; do
    ok "{\"cmd\":\"set_theme\",\"name\":\"$name\"}"
    sleep 1
    ok "{\"cmd\":\"debug_snapshot\",\"path\":\"$RAW/theme-$n.png\",\"scale\":2,\"sidebar_tab\":\"file-tree-local\"}"
    n=$((n + 1))
done

# The review tab, in a workspace with one pane so the diff has room.
ok '{"cmd":"switch_workspace","index":1}'
sleep 1
ok '{"cmd":"review_changes"}'
sleep 2.5
snap review ',"sidebar_tab":"git-panel"'

# --- Convert --------------------------------------------------------------

echo "==> convert"
webp() { cwebp -quiet -q 84 -resize "$WIDTH" 0 "$1" -o "$2"; }
PX_W=$((WIN_W * 2))
PX_H=$((WIN_H * 2))
for theme in dark light; do
    for name in hero git agents tabs workspaces palette review; do
        webp "$RAW/$name-$theme.png" "$OUT/$name-$theme.webp"
    done
    # quick-select: a closeup of the pane with the hints.
    ffmpeg -loglevel error -y -i "$RAW/quick-select-$theme.png" -vf "crop=996:700:1031:819" "$RAW/quick-select-crop-$theme.png"
    cwebp -quiet -q 84 "$RAW/quick-select-crop-$theme.png" -o "$OUT/quick-select-$theme.webp"
    # plugins: the sidebar of four shots, side by side.
    crop="crop=508:$((PX_H - 154)):$((PX_W - 520)):96"
    ffmpeg -loglevel error -y \
        -i "$RAW/hero-$theme.png" -i "$RAW/git-$theme.png" \
        -i "$RAW/agents-$theme.png" -i "$RAW/plugins-system-$theme.png" \
        -filter_complex "[0]$crop[a];[1]$crop[b];[2]$crop[c];[3]$crop[d];[a][b][c][d]hstack=4" \
        "$RAW/plugins-$theme.png"
    cwebp -quiet -q 84 "$RAW/plugins-$theme.png" -o "$OUT/plugins-$theme.webp"
    ffmpeg -loglevel error -y -i "$RAW/hero-$theme.png" -vf "scale=$WIDTH:-1" "$ROOT/documentation/public/app-$theme.png"
done
# themes: one vertical strip of each theme.
strip=$((PX_W / 4))
ffmpeg -loglevel error -y \
    -i "$RAW/theme-0.png" -i "$RAW/theme-1.png" -i "$RAW/theme-2.png" -i "$RAW/theme-3.png" \
    -filter_complex "[0]crop=$strip:$PX_H:0:0[a];[1]crop=$strip:$PX_H:$strip:0[b];[2]crop=$strip:$PX_H:$((strip * 2)):0[c];[3]crop=$strip:$PX_H:$((strip * 3)):0[d];[a][b][c][d]hstack=4" \
    "$RAW/themes.png"
webp "$RAW/themes.png" "$OUT/themes.webp"

if [ "${KEEP:-}" = 1 ]; then
    echo "raw: $RAW"
fi
echo "==> done: $OUT"

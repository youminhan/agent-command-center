#!/bin/bash
# Regenerates the README screenshots in assets/ from demo data.
# Uses its own tmux server and data folders, so your real sessions are never touched or shown.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
D="$(mktemp -d /tmp/acc-demo.XXXX)"
PORT=8811
export TMUX_TMPDIR="$D/tmux" TMUX_MANAGER_HOME="$D/data" ACC_COPILOT_HOME="$D/copilot"
unset TMUX
mkdir -p "$TMUX_TMPDIR" "$D/work"/{payments-api,web-checkout,terraform}

cleanup() {
  [[ -n "${SERVER:-}" ]] && kill "$SERVER" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  rm -rf "$D"
}
trap cleanup EXIT

python3 scripts/demo.py "$D" >/dev/null

W="$D/work"
tmux new-session -d -s payments-api -n server -c "$W/payments-api"
tmux new-window -t payments-api -n tests -c "$W/payments-api"
tmux new-window -t payments-api -n logs -c "$W/payments-api"
tmux new-session -d -s web-checkout -n dev -c "$W/web-checkout"
tmux split-window -t web-checkout -c "$W/web-checkout"
tmux new-session -d -s infra -n tf -c "$W/terraform"

# A stand-in for a running Copilot session (holds ~300 MB) in payments-api:tests.
tmux respawn-pane -k -t payments-api:tests "python3 -c 'x=b\"x\"*(300*2**20); import time; time.sleep(99999)'"
sleep 2
PID=$(tmux display -p -t payments-api:tests '#{pane_pid}')
echo "$PID" > "$ACC_COPILOT_HOME/session-state/1f0c2a77-5d3e-4b8a-9c21-7e6f00a1b201/inuse.$PID.lock"

python3 - <<'EOF'
import json, sys, time
sys.path.insert(0, ".")
import app
app.update_settings({"cleanup_copilot": True, "cleanup_copilot_days": 14, "cleanup_idle": True})
for name in ["payments-api", "web-checkout", "infra"]:
    f = app.save_session(name, auto=True)
    for hours in (1.5, 5, 30):
        d = json.loads((app.SNAP_DIR / f).read_text())
        t = time.time() - hours * 3600
        d["saved_at"] = int(t)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(t))
        (app.SNAP_DIR / f"{name}__auto-{stamp}.json").write_text(json.dumps(d))
d = json.loads((app.SNAP_DIR / f).read_text())
d["session"], d["saved_at"] = "old-spike", int(time.time() - 3 * 86400)
(app.SNAP_DIR / "old-spike__20261027-101500.json").write_text(json.dumps(d))
app.LAST_AUTOSAVE.write_text(str(time.time() - 120))
EOF

python3 app.py --port $PORT >/dev/null 2>&1 &
SERVER=$!
sleep 1

swiftc -O scripts/shot.swift -o "$D/shot" -framework Cocoa -framework WebKit 2>/dev/null
U="http://127.0.0.1:$PORT"
A="$ROOT/assets"
"$D/shot" "$U/#overview"  "$A/overview.png"  dark
"$D/shot" "$U/#sessions"  "$A/tmux.png"      light
"$D/shot" "$U/#copilot"   "$A/copilot.png"   dark  "openCp('1f0c2a77-5d3e-4b8a-9c21-7e6f00a1b201')"
"$D/shot" "$U/#snapshots" "$A/snapshots.png" light "toggleGroup('payments-api')"
"$D/shot" "$U/#cleanup"   "$A/cleanup.png"   dark
"$D/shot" "$U/#settings"  "$A/settings.png"  light
"$D/shot" "$U/#overview"  "$A/palette.png"   dark  "openPalette();document.getElementById('palq').value='pay';palRender()"

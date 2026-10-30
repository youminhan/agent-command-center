#!/bin/bash
# Installs Agent Command Center into /Applications (or ~/Applications) and opens it.
# Usage: ./install.sh [path/to/Agent Command Center.app]
# Double-clickable from the .dmg as "Install.command".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/Agent Command Center.app}"
[[ -d "$SRC" ]] || { echo "Can't find Agent Command Center.app next to this script."; exit 1; }

DEST_DIR=/Applications
[[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/Agent Command Center.app"

osascript -e 'if application id "com.agentcommandcenter.app" is running then tell application id "com.agentcommandcenter.app" to quit' 2>/dev/null || true
# Earlier versions were called "Tmux Manager"; the new app migrates their data on launch.
osascript -e 'if application id "com.tmuxmanager.app" is running then tell application id "com.tmuxmanager.app" to quit' 2>/dev/null || true
rm -rf "/Applications/Tmux Manager.app" "$HOME/Applications/Tmux Manager.app" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto "$SRC" "$DEST"
# The app is not notarized; clear the download quarantine so macOS opens it.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

command -v tmux >/dev/null || [[ -x /opt/homebrew/bin/tmux || -x /usr/local/bin/tmux ]] \
  || echo "Note: tmux is not installed. Install it with: brew install tmux"
if ! [[ -x /opt/homebrew/bin/python3 || -x /usr/local/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1; then
  echo "Note: Python 3 is needed. Install it with: xcode-select --install"
fi

echo "Installed $DEST"
open "$DEST"

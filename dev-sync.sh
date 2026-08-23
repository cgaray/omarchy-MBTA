#!/usr/bin/env bash
# Sync this repo into the installed plugin directory.
# Marketplace rule: plugin folders must contain real files, no symlinks.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="$(jq -r .id "$REPO_DIR/manifest.json")"
[[ "$PLUGIN_ID" =~ ^[a-z0-9]+([._-][a-z0-9]+)+$ ]] \
  || { echo "Invalid plugin id: $PLUGIN_ID" >&2; exit 2; }
PLUGIN_ROOT_INPUT="${HOME}/.config/omarchy/plugins"
mkdir -p "$PLUGIN_ROOT_INPUT"
PLUGIN_ROOT="$(realpath -e "$PLUGIN_ROOT_INPUT")"
[[ -d "$PLUGIN_ROOT" && "$(stat -c %u "$PLUGIN_ROOT")" = "$(id -u)" ]] \
  || { echo "Unsafe plugin root: $PLUGIN_ROOT" >&2; exit 2; }
PLUGIN_ROOT_MODE="$(stat -c %a "$PLUGIN_ROOT")"
(( (8#$PLUGIN_ROOT_MODE & 8#022) == 0 )) \
  || { echo "Plugin root is group/world writable: $PLUGIN_ROOT" >&2; exit 2; }
DEST="${PLUGIN_ROOT}/${PLUGIN_ID}"
[[ ! -L "$DEST" ]] || { echo "Refusing to sync through symlink: $DEST" >&2; exit 2; }
mkdir -p "$DEST"
[[ "$(realpath -e "$DEST")" = "$DEST" ]] \
  || { echo "Plugin destination escapes its root: $DEST" >&2; exit 2; }

rsync -av --delete --delete-excluded --safe-links \
  --exclude '.git/' \
  --exclude '__pycache__/' \
  --exclude 'tests/' \
  --exclude 'dev-sync.sh' \
  --exclude '.github/' \
  "$REPO_DIR/" "$DEST/"

echo "Synced to $DEST"
echo "Reload with: omarchy-restart-shell   (or) omarchy-shell shell rescanPlugins"

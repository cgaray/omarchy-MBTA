#!/usr/bin/env bash
# Sync this repo into the installed plugin directory.
# Marketplace rule: plugin folders must contain real files, no symlinks.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="$(jq -r .id "$REPO_DIR/manifest.json")"
DEST="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"

rsync -av --delete \
  --exclude '.git/' \
  --exclude 'tests/' \
  --exclude 'dev-sync.sh' \
  --exclude '.github/' \
  "$REPO_DIR/" "$DEST/"

echo "Synced to $DEST"
echo "Reload with: omarchy-restart-shell   (or) omarchy-shell shell rescanPlugins"

#!/usr/bin/env bash
# Shape-contract checks that do not need a running shell.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

fail() { echo "FAIL  $1"; exit 1; }
ok() { echo "  ok  $1"; }

# ---- manifest contract ----
ID="$(jq -r .id manifest.json)"
[ "$(jq -r .schemaVersion manifest.json)" = "1" ] || fail "manifest schemaVersion must be 1"
[ -n "$ID" ] || fail "manifest id missing"
[[ "$ID" != omarchy.* ]] || fail "third-party ids cannot use the omarchy.* namespace"
jq -e '.kinds | index("bar-widget")' manifest.json >/dev/null || fail "kinds must include bar-widget"

ENTRY="$(jq -r .entryPoints.barWidget manifest.json)"
[ -n "$ENTRY" ] && [ "$ENTRY" != null ] || fail "entryPoints.barWidget missing"
[ -f "$ENTRY" ] || fail "entry point file not found: $ENTRY"
ok "manifest: id=$ID kinds=bar-widget entry=$ENTRY"

# No symlinks anywhere in the plugin payload (marketplace rule).
if find . -path ./tests -prune -o -type l -print | grep -q .; then
  find . -type l
  fail "symlinks are not allowed in plugin folders"
fi
ok "no symlinks in plugin payload"

# ---- BarWidget shape contract (summon/hide routing) ----
for token in "moduleName: \"$ID\"" \
             "readonly property bool opened" \
             "function open()" \
             "function close()" \
             "function toggle()" \
             "function closeForPopoutSwitch()" \
             "readonly property bool popoutSwitchClosing" \
             "function injectPanel()" ; do
  grep -qF "$token" BarWidget.qml || fail "BarWidget.qml missing contract member: $token"
done
ok "BarWidget exposes opened/open/close/toggle/popout-switch plumbing"

grep -q 'source: Qt.resolvedUrl("Panel.qml")' BarWidget.qml || fail "BarWidget must load Panel.qml"
grep -q 'target: root.moduleName' BarWidget.qml || fail "IpcHandler should target the module id"
ok "panel loader + IPC target wired"

# ---- Panel shape contract ----
head -20 Panel.qml | grep -q "^Panel {" || fail "Panel.qml root must be a Panel"
for token in "manageIpc: false" \
             "property var anchorItem: null" \
             "property var hostWidget: null" \
             "KeyboardPanel {" \
             "PanelKeyCatcher {" \
             "onCloseRequested:" \
             "switchPanelFrom" ; do
  grep -qF "$token" Panel.qml || fail "Panel.qml missing contract member: $token"
done
ok "Panel hosts KeyboardPanel with key catcher and popout identity"

# Delegates stay pure: no processes, settings, or files inside them.
for f in ArrivalRow.qml RouteBadge.qml StationResultRow.qml; do
  grep -qE "Process|FileView|setting\(|updateEntryInline" "$f" && fail "$f must not touch data/process seams" || true
done
ok "delegates are presentation-only"

# ---- QML views may only import the Mbta.js seam ----
BAD_IMPORTS=$(grep -l 'import "\.\./' *.qml || true)
[ -z "$BAD_IMPORTS" ] || fail "views must not reach outside the plugin dir: $BAD_IMPORTS"
ok "view imports contained"

# Every Mbta.* symbol used from QML must exist in the seam. Comments are
# stripped first so prose like "built from Mbta.js" cannot fake a reference.
SYMS=$(sed 's://[^\n]*::g' *.qml | grep -vE '^[[:space:]]*import' \
  | grep -hoE '\bMbta\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^Mbta\.//' | sort -u)
if [ -n "$SYMS" ]; then
  echo "$SYMS" | while read -r sym; do
    node -e "const m=require('./Mbta.js'); process.exit(m['$sym']===undefined?1:0)" \
      || { echo "FAIL  Mbta.$sym referenced from QML but missing from Mbta.js"; exit 1; }
    echo "  ok  Mbta.$sym exists"
  done
else
  ok "no Mbta.* references from QML"
fi

echo "contract tests passed"

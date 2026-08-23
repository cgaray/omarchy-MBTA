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

grep -q 'PLUGIN_ID" =~' dev-sync.sh || fail "dev-sync.sh must validate the manifest id"
grep -q '\-L "$DEST"' dev-sync.sh || fail "dev-sync.sh must reject a symlink destination"
ok "development sync validates its destructive destination"

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

# ---- Request and route architecture ----
for f in MbtaApi.js BoundedRequest.qml RequestCoordinator.qml RequestCoordinator.js \
         PollingPolicy.js PanelActivity.js SessionCache.js ArrivalFeed.qml RouteExplorer.qml; do
  [ -f "$f" ] || fail "arrival architecture component missing: $f"
done
grep -qF 'requestProcess.command = [root.helper, String(limits.bytes), String(limits.seconds), target]' BoundedRequest.qml \
  || fail "BoundedRequest must construct an array command from a closed policy"
grep -qF 'if (root.requestBusy) return false' BoundedRequest.qml \
  || fail "BoundedRequest must allow only one in-flight request"
grep -qF 'function cancel()' BoundedRequest.qml \
  || fail "BoundedRequest must expose cancellation"
grep -qF 'onExited: function(exitCode)' BoundedRequest.qml \
  || fail "BoundedRequest must classify completion from Process.onExited"
grep -qF 'exitCode === 0 && stdout.trim() !== ""' BoundedRequest.qml \
  || fail "BoundedRequest success must require stdout and a zero exit code"
grep -qF 'signal completed(var token, string stdout)' BoundedRequest.qml \
  || fail "BoundedRequest must normalize successful completion"
grep -qF 'signal failed(var token, string reason, int exitCode)' BoundedRequest.qml \
  || fail "BoundedRequest must normalize failure"

[ "$(grep -cF 'BoundedRequest {' RequestCoordinator.qml)" = 1 ] \
  || fail "RequestCoordinator must own the only bounded request"
! grep -qF 'BoundedRequest {' ArrivalFeed.qml RouteExplorer.qml BarWidget.qml \
  || fail "workflow modules must submit intents instead of owning transport"
grep -qF 'RequestCoordinator {' BarWidget.qml \
  || fail "BarWidget must host the always-mounted request coordinator"
for token in 'function refreshNow()' 'function refreshIfStale()' \
             'property var board:' 'property bool loading:' \
              'property string errorText:' 'property date lastUpdated:' \
              'readonly property string nextLabel:' 'readonly property bool hasData:' \
              'Mbta.scheduleWindow(new Date())' 'root.api.schedules(root.configuredStopIds, window, Date.now())' \
              'PollingPolicy.reconcile' 'root.requests.request' \
             'root.board.nextMs <= root.nowMs'; do
  grep -qF "$token" ArrivalFeed.qml || fail "ArrivalFeed missing contract: $token"
done
! grep -qE 'id: (predictionsProc|schedulesProc|tickTimer|refreshTimer)' BarWidget.qml \
  || fail "BarWidget must not retain arrival processes or timers"
! grep -qE 'function (applyPredictions|applySchedules|maybeFallbackToSchedules|rebuildBoard)\(' BarWidget.qml \
  || fail "BarWidget must not retain arrival implementation functions"
grep -qF 'ArrivalFeed {' BarWidget.qml || fail "BarWidget must host ArrivalFeed"
grep -qF 'MbtaApi.create(Mbta)' ArrivalFeed.qml \
  || fail "ArrivalFeed must use the paired request/payload seam"
for token in 'property string activeLineTripId:' \
              'property int lineGeneration:' 'property var pollingState:' \
              'function toggleLine(group)' 'function closeLine()' \
              'PollingPolicy.reconcile' 'root.requests.request'; do
  grep -qF "$token" RouteExplorer.qml || fail "RouteExplorer missing ownership contract: $token"
done
! grep -qE 'id: (systemMapProc|routePreviewProc|lineStopsProc|lineVehiclesProc|previewDebounce|lineTransitionTimer)' BarWidget.qml \
  || fail "BarWidget must not retain route processes or timers"
! grep -qE 'property (var|string|bool|int) (previewRouteCache|lineGeneration|exactTripStopsCache|activeLineTripId):' BarWidget.qml \
  || fail "BarWidget must not retain route cache or selected-trip implementation"
grep -qF 'RouteExplorer {' BarWidget.qml || fail "BarWidget must host RouteExplorer"
ok "coordinator, polling policy, and workflows have isolated ownership"

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

grep -A8 'id: chipNameLabel' Panel.qml | grep -q 'textFormat: Text.PlainText' \
  || fail "configured station labels must render as plain text"
ok "API-derived labels are presentation-bounded"

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

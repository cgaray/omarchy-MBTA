#!/usr/bin/env bash
# CI entrypoint. Requires node, jq, bash; qmllint is optional.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== node tests =="
node "$DIR/mbta-test.js"
node "$DIR/mbta-api-test.js"
node "$DIR/architecture-test.js"

echo "== qml refs =="
node "$DIR/refs-test.js"

echo "== contract =="
bash "$DIR/contract-test.sh"

echo "== shell syntax =="
bash -n "$DIR/../dev-sync.sh"
echo "  ok  dev-sync.sh parses"

echo "== helper syntax =="
python3 -c 'import ast, pathlib, sys; [ast.parse(pathlib.Path(p).read_text()) for p in sys.argv[1:]]' \
  "$DIR/../bin/mbta-fetch"
echo "  ok  bounded helpers parse"

echo "== security helpers =="
python3 "$DIR/security-test.py"

if command -v qmllint >/dev/null 2>&1 && [ -n "${OMARCHY_PATH:-}" ]; then
  echo "== qmllint =="
  status=0
  # BarWidget.qml is excluded: any resolved IpcHandler with function
  # declarations crashes this qmllint (exit 255, no diagnostics) — the same
  # first-party limitation arcade's suite documents. contract-test.sh covers
  # the widget's runtime shape instead.
  for f in Panel.qml ArrivalFeed.qml BoundedRequest.qml RouteExplorer.qml ArrivalRow.qml RouteBadge.qml StationResultRow.qml; do
    if qmllint -I "$OMARCHY_PATH/shell" "$DIR/../$f"; then
      echo "  ok  $f"
    else
      echo "FAIL  $f"
      status=1
    fi
  done
  [ "$status" = 0 ] || exit 1
else
  echo "qmllint skipped (not installed or OMARCHY_PATH unset)"
fi

echo "ALL PASSED"

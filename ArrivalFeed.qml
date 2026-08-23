import QtQuick
import "Mbta.js" as Mbta
import "MbtaApi.js" as MbtaApi
import "PollingPolicy.js" as PollingPolicy

// Arrival domain workflow. PollingPolicy decides when work is due,
// RequestCoordinator executes it, and this module owns only board semantics.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  required property var requests
  property var configuredStopIds: []
  property int refreshSec: 60
  property int perGroupCap: 3
  property bool scheduleFallback: true
  property string pinnedLineKey: ""
  readonly property var api: MbtaApi.create(Mbta)

  property var board: null
  property bool loading: false
  property string errorText: ""
  property date lastUpdated: new Date(0)
  property real nowMs: Date.now()
  readonly property bool stale: lastUpdated.getTime() <= 0
    || nowMs - lastUpdated.getTime() >= refreshSec * 1000
  readonly property string nextLabel: pinnedLineKey !== ""
    ? Mbta.pinnedNextLabel(board, pinnedLineKey, nowMs)
    : (board && !isNaN(board.nextMs) ? Mbta.countdownLabel(board.nextMs - nowMs) : "")
  readonly property bool hasData: board !== null && nextLabel !== ""

  property var lastRows: []
  property var lastIndex: ({ route: Mbta.dictionary(), trip: Mbta.dictionary(), stop: Mbta.dictionary() })
  property real lastRefreshStartedMs: 0
  property var pollingState: PollingPolicy.create()

  signal boardRefreshed()

  QtObject { id: arrivalOwner }

  function demand() {
    return {
      jobId: "arrivals",
      revision: Mbta.serializeStopIds(root.configuredStopIds),
      mode: "interval",
      enabled: root.configuredStopIds.length > 0,
      ready: true,
      everyMs: root.refreshSec * 1000
    }
  }

  function rebuildBoard() {
    root.board = Mbta.buildBoard(root.lastRows || [], root.lastIndex,
      root.configuredStopIds, root.nowMs, root.perGroupCap)
  }

  function scheduleWake(nextWakeMs) {
    pollWake.stop()
    if (nextWakeMs === null || nextWakeMs === undefined) return
    pollWake.interval = Math.max(1, Number(nextWakeMs) - Date.now())
    pollWake.start()
  }

  function reconcilePolling() {
    var result = PollingPolicy.reconcile(root.pollingState, Date.now(), [root.demand()])
    root.pollingState = result.state
    for (var i = 0; i < result.effects.length; i++) {
      var effect = result.effects[i]
      if (effect.type === "cancel") {
        root.requests.cancelOwner(arrivalOwner)
        root.loading = false
      } else if (effect.type === "start") {
        root.startPredictions(effect.token)
      }
    }
    root.scheduleWake(result.nextWakeMs)
  }

  function finishPoll(token) {
    var completed = PollingPolicy.complete(root.pollingState, Date.now(), {
      token: token, disposition: "success"
    })
    root.pollingState = completed.state
    root.reconcilePolling()
  }

  function startPredictions(token) {
    root.loading = true
    root.lastRefreshStartedMs = Date.now()
    var request = root.api.predictions(root.configuredStopIds, Date.now())
    root.requests.request(arrivalOwner, request, root.requests.background, function(outcome) {
      if (outcome.status !== "ok") {
        root.loading = false
        root.errorText = outcome.error.kind === "rate-limited"
          ? "MBTA rate limit reached; retrying soon" : "MBTA request failed"
        root.finishPoll(token)
        return
      }
      var accepted = outcome.value
      root.lastIndex = accepted.index
      root.lastRows = accepted.rows
      if (!accepted.rows.length && root.scheduleFallback) {
        root.startSchedules(token)
        return
      }
      root.loading = false
      root.errorText = ""
      root.lastUpdated = new Date()
      root.rebuildBoard()
      root.boardRefreshed()
      root.finishPoll(token)
    })
  }

  function startSchedules(token) {
    var window = Mbta.scheduleWindow(new Date())
    var request = root.api.schedules(root.configuredStopIds, window, Date.now())
    root.requests.request(arrivalOwner, request, root.requests.background, function(outcome) {
      root.loading = false
      if (outcome.status === "ok") {
        root.lastIndex = outcome.value.index
        root.lastRows = outcome.value.rows
        root.errorText = ""
        root.lastUpdated = new Date()
      } else {
        root.errorText = outcome.error.kind === "rate-limited"
          ? "MBTA rate limit reached; retrying soon" : "MBTA request failed"
      }
      root.rebuildBoard()
      root.boardRefreshed()
      root.finishPoll(token)
    })
  }

  function refreshIfStale() { root.reconcilePolling() }

  function refreshNow() {
    root.pollingState = PollingPolicy.force(root.pollingState, Date.now(), "arrivals").state
    root.reconcilePolling()
  }

  onConfiguredStopIdsChanged: {
    root.rebuildBoard()
    root.reconcilePolling()
  }
  onRefreshSecChanged: root.reconcilePolling()
  onNowMsChanged: {
    if (root.board && !isNaN(root.board.nextMs) && root.board.nextMs <= root.nowMs)
      root.rebuildBoard()
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: pollWake
    repeat: false
    onTriggered: root.reconcilePolling()
  }

  Component.onCompleted: root.reconcilePolling()
  Component.onDestruction: root.requests.cancelOwner(arrivalOwner)
}

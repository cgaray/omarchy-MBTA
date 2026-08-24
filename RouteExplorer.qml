import QtQuick
import "Mbta.js" as Mbta
import "MbtaApi.js" as MbtaApi
import "PollingPolicy.js" as PollingPolicy

// Route exploration workflow. Static and preview requests use coordinator
// caching; selected-trip and vehicle cadence use the deterministic policy.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  required property var requests
  property var board: null
  property string activityMode: "hidden"
  // Injected by the host so all workflows share one descriptor seam.
  property var api: MbtaApi.create(Mbta)

  property string activeLineKey: ""
  property string activeLineRouteId: ""
  property string activeLineTripId: ""
  property int activeLineDirectionId: -1
  property string activeLineHeadsign: ""
  property string activeLineStopId: ""
  property var activeLineBadge: null
  property var lineStops: []
  property var lineVehicles: []
  property bool lineLoading: false
  property string lineError: ""
  property bool lineVisible: false
  property int lineGeneration: 0
  property int lineRetryCount: 0
  property int lineAttemptRevision: 0
  property bool lineWasActive: false
  property var pollingState: PollingPolicy.create()
  readonly property string activeLinePinKey: activeLineKey === ""
    ? "" : activeLineStopId + "|" + activeLineKey

  QtObject { id: lineStopsOwner }
  QtObject { id: lineVehiclesOwner }

  function toggleLine(group) {
    if (!group) return
    var groupKey = String(group.key)
    var stopId = String(group.stopId || "")
    if (root.lineVisible && root.activeLineKey === groupKey
        && root.activeLineStopId === stopId) {
      root.closeLine()
      return
    }
    if (root.lineVisible && root.activeLineKey === groupKey
        && root.activeLineTripId === String(group.tripId || "")) {
      root.activeLineStopId = stopId
      return
    }
    root.openLine(group)
  }

  function openLine(group) {
    if (!group) return
    lineTransitionTimer.stop()
    root.activeLineKey = String(group.key)
    root.activeLineRouteId = String(group.routeId)
    root.activeLineTripId = String(group.tripId || "")
    root.activeLineDirectionId = Number(group.directionId)
    root.activeLineHeadsign = String(group.headsign || "")
    root.activeLineStopId = String(group.stopId || "")
    root.activeLineBadge = group.badge
    root.lineStops = []
    root.lineVehicles = []
    root.lineError = ""
    root.lineLoading = true
    root.lineVisible = true
    root.lineGeneration++
    root.lineRetryCount = 0
    root.lineAttemptRevision++
    if (root.activeLineTripId === "") {
      root.lineLoading = false
      root.lineError = "No route trip available"
    }
    root.reconcileLinePolling()
  }

  function closeLine() {
    root.lineVisible = false
    root.lineGeneration++
    root.reconcileLinePolling()
    lineTransitionTimer.restart()
  }

  function lineDemands() {
    var lineEnabled = (root.activityMode === "line" || root.activityMode === "split-line")
      && root.lineVisible
    return [
      { jobId: "line-stops", revision: root.activeLineTripId + "|" + root.lineAttemptRevision, mode: "once",
        enabled: lineEnabled && root.activeLineTripId !== "", ready: root.lineStops.length === 0 },
      { jobId: "line-vehicles", revision: root.activeLineRouteId + "|"
          + root.activeLineDirectionId + "|" + root.activeLineTripId,
        mode: "interval", enabled: lineEnabled, ready: root.lineStops.length > 0,
        everyMs: 60000 }
    ]
  }

  function scheduleLineWake(nextWakeMs) {
    lineWake.stop()
    if (nextWakeMs === null || nextWakeMs === undefined) return
    lineWake.interval = Math.max(1, Number(nextWakeMs) - Date.now())
    lineWake.start()
  }

  function reconcileLinePolling() {
    var result = PollingPolicy.reconcile(root.pollingState, Date.now(), root.lineDemands())
    root.pollingState = result.state
    for (var i = 0; i < result.effects.length; i++) {
      var effect = result.effects[i]
      if (effect.type === "cancel") {
        if (effect.jobId === "line-stops") root.requests.cancelOwner(lineStopsOwner)
        else if (effect.jobId === "line-vehicles") root.requests.cancelOwner(lineVehiclesOwner)
      } else if (effect.jobId === "line-stops") root.startLineStops(effect.token)
      else if (effect.jobId === "line-vehicles") root.startLineVehicles(effect.token)
    }
    root.scheduleLineWake(result.nextWakeMs)
  }

  function completeLineJob(token, disposition, retryAtMs) {
    var completed = PollingPolicy.complete(root.pollingState, Date.now(), {
      token: token, disposition: disposition, retryAtMs: retryAtMs
    })
    root.pollingState = completed.state
    root.reconcileLinePolling()
  }

  function startLineStops(token) {
    var tripId = root.activeLineTripId
    var generation = root.lineGeneration
    root.lineLoading = true
    root.requests.request(lineStopsOwner, root.api.exactTripStops(tripId, generation),
      root.requests.interactive, function(outcome) {
        if (generation !== root.lineGeneration || tripId !== root.activeLineTripId) return
        if (outcome.status !== "ok") {
          if (outcome.error.kind === "rate-limited" && root.lineRetryCount < 1) {
            root.lineRetryCount++
            root.lineError = "MBTA is busy; retrying…"
            root.completeLineJob(token, "retry", Date.now() + 60000)
            return
          }
          root.lineLoading = false
          root.lineError = "Could not load route stops"
          root.completeLineJob(token, "terminal", 0)
          return
        }
        root.lineStops = outcome.value
        if (!root.lineStops.length) {
          root.lineLoading = false
          root.lineError = "No route stops found"
        }
        root.completeLineJob(token, "success", 0)
      })
  }

  function startLineVehicles(token) {
    var generation = root.lineGeneration
    var request = root.api.vehicles(root.activeLineRouteId,
      root.activeLineDirectionId, root.lineStops, generation)
    root.requests.request(lineVehiclesOwner, request, root.requests.background, function(outcome) {
      if (generation !== root.lineGeneration) return
      root.lineLoading = false
      if (outcome.status === "ok") {
        root.lineVehicles = outcome.value
        root.lineError = ""
      } else {
        root.lineError = "Live vehicles unavailable"
      }
      root.completeLineJob(token, "success", 0)
    })
  }

  Timer { id: lineWake; repeat: false; onTriggered: root.reconcileLinePolling() }
  Timer {
    id: lineTransitionTimer
    interval: 60
    onTriggered: {
      root.activeLineKey = ""
      root.activeLineRouteId = ""
      root.activeLineTripId = ""
      root.activeLineDirectionId = -1
      root.activeLineHeadsign = ""
      root.activeLineStopId = ""
      root.activeLineBadge = null
      root.lineStops = []
      root.lineVehicles = []
      root.lineLoading = false
      root.lineError = ""
      root.reconcileLinePolling()
    }
  }

  onActivityModeChanged: {
    var lineActive = root.activityMode === "line" || root.activityMode === "split-line"
    if (lineActive && !root.lineWasActive && root.lineVisible && !root.lineStops.length)
      root.lineAttemptRevision++
    root.lineWasActive = lineActive
    root.reconcileLinePolling()
  }

  Component.onDestruction: {
    root.requests.cancelOwner(lineStopsOwner)
    root.requests.cancelOwner(lineVehiclesOwner)
  }
}

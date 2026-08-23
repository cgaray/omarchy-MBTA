import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Mbta.js" as Mbta
import "MbtaApi.js" as MbtaApi

// MBTA bar widget: a transit icon plus the next departure across every
// configured stop, refreshed live from api-v3.mbta.com. Clicking opens the
// departure-board panel, which also hosts the station picker.
BarWidget {
  id: root
  moduleName: "io.github.cgaray.mbta"

  // ---- Settings compatibility surface. MbtaSettings owns all interpretation
  // and mutations; the host adapter only echoes and persists a complete entry.
  readonly property var configuredStopIds: settingsAdapter.configuredStopIds
  readonly property int refreshSec: settingsAdapter.refreshSec
  readonly property int perGroupCap: settingsAdapter.perGroupCap
  readonly property bool scheduleFallback: settingsAdapter.scheduleFallback
  readonly property string pinnedLineKey: settingsAdapter.pinnedLineKey
  readonly property var mbtaSettings: settingsAdapter
  readonly property string fetchHelper: String(Qt.resolvedUrl("bin/mbta-fetch")).replace(/^file:\/\//, "")
  readonly property var api: MbtaApi.create(Mbta)

  RequestCoordinator {
    id: requests
    helper: root.fetchHelper
  }

  QtObject { id: stationsOwner }
  QtObject { id: geocodeOwner }
  QtObject { id: nearbyOwner }

  QtObject {
    id: settingsOwnerAdapter

    function applySettingsEntry(entry) {
      root.settings = entry
      if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
        root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  MbtaSettings {
    id: settingsAdapter
    ownerAdapter: settingsOwnerAdapter
    source: root.settings || ({})
  }

  // ---- Arrival-feed compatibility surface consumed by Panel, IPC, and the bar.
  readonly property var board: arrivalFeed.board
  readonly property bool loading: arrivalFeed.loading
  readonly property string errorText: arrivalFeed.errorText
  readonly property date lastUpdated: arrivalFeed.lastUpdated
  readonly property real lastRefreshStartedMs: arrivalFeed.lastRefreshStartedMs
  readonly property real nowMs: arrivalFeed.nowMs
  readonly property string nextLabel: arrivalFeed.nextLabel
  readonly property bool hasData: arrivalFeed.hasData

  function refreshIfStale() { arrivalFeed.refreshIfStale() }
  function refreshNow() { arrivalFeed.refreshNow() }

  ArrivalFeed {
    id: arrivalFeed
    requests: requests
    configuredStopIds: root.configuredStopIds
    refreshSec: root.refreshSec
    perGroupCap: root.perGroupCap
    scheduleFallback: root.scheduleFallback
    pinnedLineKey: root.pinnedLineKey
  }

  // Station picker cache (full system station list, fetched once per session).
  property var stationsCache: null
  property bool stationsLoading: false
  property real stationsLastAttemptMs: 0

  // ---- Nearby-station state
  // Nearby searches always use coordinates or an address supplied by the user.
  property var lastOrigin: null
  property var nearbyResults: []
  property bool nearbyLoading: false
  property bool locating: false
  property string nearbyError: ""
  property real pendingRadiusKm: 1

  // Compatibility surface while Panel remains hosted by the bar widget.
  readonly property string activeLineKey: routeExplorer.activeLineKey
  readonly property string activeLineHeadsign: routeExplorer.activeLineHeadsign
  readonly property string activeLineStopId: routeExplorer.activeLineStopId
  readonly property var activeLineBadge: routeExplorer.activeLineBadge
  readonly property var lineStops: routeExplorer.lineStops
  readonly property var lineVehicles: routeExplorer.lineVehicles
  readonly property bool lineLoading: routeExplorer.lineLoading
  readonly property string lineError: routeExplorer.lineError
  readonly property bool lineVisible: routeExplorer.lineVisible
  readonly property string activeLinePinKey: routeExplorer.activeLinePinKey

  RouteExplorer {
    id: routeExplorer
    requests: requests
    board: root.board
    activityMode: panelLoader.item ? panelLoader.item.activity.mode : "hidden"
  }

  function ensureStations() {
    if (root.stationsCache !== null || root.stationsLoading) return
    if (root.stationsLastAttemptMs > 0 && Date.now() - root.stationsLastAttemptMs < 600000) return
    root.stationsLastAttemptMs = Date.now()
    root.stationsLoading = true
    requests.request(stationsOwner, root.api.stations(), requests.interactive, function(outcome) {
      root.stationsLoading = false
      if (outcome.status === "ok") root.stationsCache = outcome.value
      else console.warn("[mbta] station list unavailable:", outcome.error.kind)
    })
  }


  function searchStations(query) {
    var q = String(query || "").replace(/^\s+|\s+$/g, "")
    if (q === "" || root.stationsCache === null) return []
    // 16 keeps word-start matches visible when a street name prefixes many
    // stops ("Appleton St @ …") without drowning the list.
    return Mbta.filterStations(root.stationsCache, q, 16)
  }

  // ---- Nearby-station flows. Both entry points converge on fetchNearby.
  function findNearby(addressText, radiusKm) {
    root.nearbyError = ""
    var coords = Mbta.parseLatLon(addressText)
    if (coords) {
      fetchNearby(coords.latitude, coords.longitude, radiusKm, "coordinates")
      return true
    }
    var query = String(addressText || "").slice(0, 200).replace(/^\s+|\s+$/g, "")
    if (query === "") {
      root.nearbyError = "Enter your location"
      return false
    }
    if (root.locating) return false
    var request = root.api.geocode(query)
    root.pendingRadiusKm = radiusKm
    root.locating = true
    return requests.request(geocodeOwner, request, requests.interactive, function(outcome) {
      root.locating = false
      if (outcome.status !== "ok" || !outcome.value.length) {
        root.nearbyError = "Address not found"
        return
      }
      var hit = outcome.value[0]
      root.fetchNearby(hit.latitude, hit.longitude, root.pendingRadiusKm, hit.name)
    }) > 0
  }

  function fetchNearby(latitude, longitude, radiusKm, sourceLabel) {
    if (root.nearbyLoading) return
    root.lastOrigin = {
      latitude: latitude,
      longitude: longitude,
      source: String(sourceLabel || "location")
    }
    var request = root.api.nearby(latitude, longitude, radiusKm)
    root.nearbyLoading = true
    requests.request(nearbyOwner, request, requests.interactive, function(outcome) {
      root.nearbyLoading = false
      if (outcome.status !== "ok") {
        root.nearbyResults = []
        root.nearbyError = outcome.error.kind === "rate-limited"
          ? "MBTA rate limit reached; retry shortly" : "MBTA request failed"
        return
      }
      root.nearbyResults = outcome.value
      root.nearbyError = root.nearbyResults.length ? "" : "No stations found in that radius"
    })
  }

  function readSetting(name, fallback) { return settingsAdapter.value(name, fallback) }
  function updateSettings(patch) { return settingsAdapter.update(patch) }

  function setStopIds(ids) {
    settingsAdapter.setStopIds(ids)
    Qt.callLater(refreshNow)
  }

  function toggleStop(id) {
    if (settingsAdapter.toggleStop(id)) Qt.callLater(refreshNow)
  }

  function togglePinnedLine() {
    settingsAdapter.togglePinnedLine(root.activeLinePinKey)
  }

  function toggleLine(group) { routeExplorer.toggleLine(group) }
  function closeLine() { routeExplorer.closeLine() }

  // ---- Panel lifecycle plumbing (shape contract for summon/hide routing).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  property string pendingPanelAction: ""

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) {
      panelLoader.item.openFromHotkey()
      return
    }
    root.pendingPanelAction = "open"
    panelLoader.active = true
  }

  function close() {
    root.pendingPanelAction = ""
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle) {
      panelLoader.item.toggle()
      return
    }
    root.pendingPanelAction = "open"
    panelLoader.active = true
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function completePanelLoad() {
    root.injectPanel()
    var action = root.pendingPanelAction
    root.pendingPanelAction = ""
    if (action === "open" && panelLoader.item && panelLoader.item.openFromHotkey)
      panelLoader.item.openFromHotkey()
  }

  // WidgetButton's default width only accounts for one icon. Reserve the
  // custom icon-and-countdown row so the next bar module cannot overlap it.
  implicitWidth: contentRow.implicitWidth + Style.space(14)
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: false
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.completePanelLoad)
    }
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshNow() }

    function status(): string {
      var stops = []
      if (root.board && root.board.stops) {
        for (var i = 0; i < root.board.stops.length; i++) {
          var stop = root.board.stops[i]
          var lines = []
          for (var g = 0; g < stop.groups.length; g++) {
            var group = stop.groups[g]
            lines.push(group.badge.label + (group.headsign ? " → " + group.headsign : "") + ": " + group.times.map(function(t) { return t.label }).join(" "))
          }
          stops.push({ stop: stop.name, id: stop.id, lines: lines })
        }
      }
      return JSON.stringify({
        ok: root.errorText === "",
        next: root.nextLabel,
        loading: root.loading,
        error: root.errorText,
        updated: root.lastUpdated.getTime() > 0 ? root.lastUpdated.toISOString() : null,
        stops: stops
      })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.hasData
      ? "MBTA — " + (root.pinnedLineKey !== "" ? "pinned departure " : "next departure ") + root.nextLabel + ", click for arrivals"
      : "MBTA — no live departures"

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
      else if (b === Qt.MiddleButton) root.refreshNow()
      else if (b === Qt.RightButton) root.refreshNow()
    }

    // Vector train asset (assets/train.svg) — crisp at any bar size, same
    // Image-asset pattern the agents plugin uses for provider marks.
    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(7)

      Image {
        source: Qt.resolvedUrl("assets/train.svg")
        sourceSize.width: Math.round(button.height * 0.72)
        sourceSize.height: Math.round(button.height * 0.72)
        fillMode: Image.PreserveAspectFit
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: !(button.bar && button.bar.vertical) && text !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: root.errorText !== "" ? "!" : (root.hasData ? root.nextLabel : "")
        color: root.errorText !== "" ? button.activeColor : (root.hasData ? button.foreground : Qt.alpha(button.foreground, 0.55))
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }
    }
  }
}

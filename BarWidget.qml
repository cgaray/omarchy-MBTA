import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Mbta.js" as Mbta

// MBTA bar widget: a transit icon plus the next departure across every
// configured stop, refreshed live from api-v3.mbta.com. Clicking opens the
// departure-board panel, which also hosts the station picker.
BarWidget {
  id: root
  moduleName: "io.github.cgaray.mbta"

  // ---- Settings (inline shell.json entry for this module)
  readonly property var configuredStopIds: Mbta.parseStopIds(setting("stopIds", Mbta.serializeStopIds(Mbta.DEFAULT_STOP_IDS)))
  readonly property int refreshSec: Math.max(15, Math.min(300, parseInt(setting("refreshSec", 30), 10) || 30))
  readonly property int perGroupCap: Math.max(1, Math.min(6, parseInt(setting("perGroupCap", 3), 10) || 3))
  readonly property bool scheduleFallback: setting("scheduleFallback", true) !== false
  readonly property string pinnedLineKey: String(setting("pinnedLine", "") || "").slice(0, 300)
  readonly property string fetchHelper: String(Qt.resolvedUrl("bin/mbta-fetch")).replace(/^file:\/\//, "")
  readonly property string weatherReader: String(Qt.resolvedUrl("bin/read-weather-location")).replace(/^file:\/\//, "")

  // ---- Live data state
  // Raw rows and the included-index survive between fetches; `board` is
  // rebuilt from them on each clock tick so countdown labels stay honest
  // without re-fetching.
  property var lastRows: []
  property var lastIndex: ({ route: {}, trip: {}, stop: {} })
  property var board: null
  property bool loading: false
  property string errorText: ""
  property date lastUpdated: new Date(0)
  property real nowMs: Date.now()
  property int refreshGeneration: 0

  // Station picker cache (full system station list, fetched once per session).
  property var stationsCache: null
  property bool stationsLoading: false

  // ---- Nearby-station state
  // Origin resolution order: coordinates saved by the weather plugin, a
  // session-cached IP fix, then typed addresses via Nominatim.
  property var weatherLocationState: null
  property var ipLocation: null
  property var lastOrigin: null
  property var nearbyResults: []
  property bool nearbyLoading: false
  property bool locating: false
  property string nearbyError: ""
  property real pendingRadiusKm: 1
  property bool pendingNearbyAfterLocate: false

  // One expanded route strip is shared by the panel's departure rows.
  property string activeLineKey: ""
  property string activeLineRouteId: ""
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

  readonly property string nextLabel: pinnedLineKey !== ""
    ? Mbta.pinnedNextLabel(board, pinnedLineKey)
    : (board && board.nextLabel ? board.nextLabel : "")
  readonly property bool hasData: board !== null && nextLabel !== ""
  readonly property string activeLinePinKey: activeLineKey === "" ? "" : activeLineStopId + "|" + activeLineKey

  function rebuildBoard() {
    if (!root.lastRows || root.lastRows.length === 0) {
      // Keep an empty-shaped board so the panel renders stop sections.
      root.board = Mbta.buildBoard([], root.lastIndex, root.configuredStopIds, root.nowMs, root.perGroupCap)
      return
    }
    root.board = Mbta.buildBoard(root.lastRows, root.lastIndex, root.configuredStopIds, root.nowMs, root.perGroupCap)
  }

  function fetchCommand(limitBytes, timeoutSec, url) {
    return [root.fetchHelper, String(limitBytes), String(timeoutSec), url]
  }

  onNowMsChanged: rebuildBoard()
  onConfiguredStopIdsChanged: rebuildBoard()

  function refreshNow() {
    if (predictionsProc.running) return
    // An empty stop list would 400 against the API every cycle; the panel's
    // "No stations yet" hint is the right surface for that state.
    if (!root.configuredStopIds.length) {
      root.loading = false
      rebuildBoard()
      return
    }
    root.loading = true
    root.refreshGeneration++
    predictionsProc.generation = root.refreshGeneration
    var url = Mbta.predictionsUrl(root.configuredStopIds)
    predictionsProc.command = fetchCommand(1048576, 8, url)
    predictionsProc.running = true
  }

  function applyPredictions(raw, generation) {
    if (generation !== root.refreshGeneration) return
    root.loading = false
    var trimmed = String(raw || "").trim()
    if (trimmed === "" || !root.configuredStopIds.length) {
      maybeFallbackToSchedules()
      return
    }
    try {
      var payload = JSON.parse(trimmed)
      var index = Mbta.indexIncluded(payload.included)
      var rows = Mbta.collectRows(payload, Date.now(), true)
      root.lastIndex = index
      root.lastRows = rows
      if (rows.length === 0 && root.scheduleFallback) {
        maybeFallbackToSchedules()
        return
      }
      root.errorText = ""
      root.lastUpdated = new Date()
      rebuildBoard()
    } catch (e) {
      console.warn("[mbta] predictions parse failed:", e.message)
      root.errorText = "MBTA response error"
    }
  }

  function maybeFallbackToSchedules() {
    if (!root.scheduleFallback || schedulesProc.running || !root.configuredStopIds.length) return
    var window = Mbta.scheduleWindow(new Date())
    var url = Mbta.schedulesUrl(root.configuredStopIds, window.min, window.max)
    schedulesProc.command = fetchCommand(1048576, 8, url)
    schedulesProc.generation = root.refreshGeneration
    schedulesProc.running = true
  }

  function applySchedules(raw, generation) {
    if (generation !== root.refreshGeneration) return
    var trimmed = String(raw || "").trim()
    if (trimmed === "") {
      rebuildBoard()
      return
    }
    try {
      var payload = JSON.parse(trimmed)
      root.lastIndex = Mbta.indexIncluded(payload.included)
      root.lastRows = Mbta.collectRows(payload, Date.now(), false)
      root.errorText = ""
      root.lastUpdated = new Date()
    } catch (e) {
      root.errorText = "MBTA response error"
    }
    rebuildBoard()
  }

  function ensureStations() {
    if (root.stationsCache !== null || stationsProc.running) return
    root.stationsLoading = true
    stationsProc.command = fetchCommand(4194304, 15, Mbta.stationsUrl())
    stationsProc.running = true
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
    if (query === "" || geocodeProc.running) return false
    root.pendingRadiusKm = radiusKm
    root.locating = true
    geocodeProc.command = fetchCommand(65536, 10, Mbta.geocodeUrl(query))
    geocodeProc.running = true
    return true
  }

  function useMyLocation(radiusKm) {
    root.nearbyError = ""
    var weatherLocation = root.weatherLocationState
    if (weatherLocation && !isNaN(weatherLocation.latitude)) {
      fetchNearby(
        weatherLocation.latitude,
        weatherLocation.longitude,
        radiusKm,
        "saved location" + (weatherLocation.name !== "" ? " · " + weatherLocation.name : "")
      )
      return true
    }
    if (root.ipLocation) {
      fetchNearby(root.ipLocation.latitude, root.ipLocation.longitude, radiusKm, "IP location")
      return true
    }
    if (ipLocProc.running) return false
    root.pendingRadiusKm = radiusKm
    root.pendingNearbyAfterLocate = true
    root.locating = true
    ipLocProc.command = fetchCommand(1024, 8, "https://ipinfo.io/loc")
    ipLocProc.running = true
    return true
  }

  function fetchNearby(latitude, longitude, radiusKm, sourceLabel) {
    if (nearbyProc.running) return
    root.lastOrigin = {
      latitude: latitude,
      longitude: longitude,
      source: String(sourceLabel || "location")
    }
    root.nearbyLoading = true
    nearbyProc.command = fetchCommand(1048576, 12,
      Mbta.nearbyUrl(latitude, longitude, radiusKm))
    nearbyProc.running = true
  }

  // Settings persistence follows the clock's cycleFormat: apply locally so the
  // change is instant, then let shell.json echo the same value back.
  function updateSettings(patch) {
    var entry = {}
    for (var key in root.settings)
      if (key !== "id") entry[key] = root.settings[key]
    for (var patchKey in patch) entry[patchKey] = patch[patchKey]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    return entry
  }

  function setStopIds(ids) {
    updateSettings({ stopIds: Mbta.serializeStopIds(ids) })
    Qt.callLater(refreshNow)
  }

  function toggleStop(id) {
    var ids = root.configuredStopIds.slice()
    var at = ids.indexOf(id)
    if (at >= 0) ids.splice(at, 1)
    else ids.push(id)
    setStopIds(ids)
  }

  function togglePinnedLine() {
    if (root.activeLinePinKey === "") return
    updateSettings({ pinnedLine: root.pinnedLineKey === root.activeLinePinKey ? "" : root.activeLinePinKey })
  }

  function toggleLine(group) {
    if (!group) return
    var groupKey = String(group.key)
    var stopId = String(group.stopId || "")
    var sameRow = root.lineVisible && root.activeLineKey === groupKey
      && root.activeLineStopId === stopId

    if (sameRow) {
      closeLine()
      return
    }

    // The route data is shared across configured stations. Move the selected
    // station marker without duplicating or re-fetching the detail view.
    if (root.lineVisible && root.activeLineKey === groupKey) {
      root.activeLineStopId = stopId
      return
    }

    // Replace the detail in place so the panel keeps a stable width and
    // height while moving between routes.
    if (lineStopsProc.running) lineStopsProc.running = false
    if (lineVehiclesProc.running) lineVehiclesProc.running = false
    openLine(group)
  }

  function closeLine() {

    // Collapse the visual immediately. Model teardown and any next route load
    // happen on a later tick so they cannot stall the click frame.
    root.lineVisible = false
    root.lineGeneration++
    if (lineStopsProc.running) lineStopsProc.running = false
    if (lineVehiclesProc.running) lineVehiclesProc.running = false
    lineTransitionTimer.restart()
  }

  function openLine(group) {
    if (!group) return
    lineTransitionTimer.stop()
    root.activeLineKey = String(group.key)
    root.activeLineRouteId = String(group.routeId)
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
    lineStopsProc.generation = root.lineGeneration
    lineStopsProc.command = fetchCommand(1048576, 10,
      Mbta.lineStopsUrl(root.activeLineRouteId, root.activeLineDirectionId))
    lineStopsProc.running = true
  }

  Timer {
    id: lineTransitionTimer
    interval: 60
    onTriggered: {
      root.activeLineKey = ""
      root.lineStops = []
      root.lineVehicles = []
    }
  }

  function refreshLineVehicles() {
    if (root.activeLineKey === "" || !root.lineStops.length || lineVehiclesProc.running) return
    lineVehiclesProc.command = fetchCommand(1048576, 8,
      Mbta.vehiclesUrl(root.activeLineRouteId, root.activeLineDirectionId))
    lineVehiclesProc.generation = root.lineGeneration
    lineVehiclesProc.running = true
  }

  // Processes are declared before the timers on purpose: with
  // triggeredOnStart, refreshTimer fires while the component tree is still
  // being built, and sibling ids declared later would not resolve yet.
  Process {
    id: predictionsProc
    property int generation: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPredictions(text, predictionsProc.generation)
    }
  }

  Process {
    id: schedulesProc
    property int generation: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySchedules(text, schedulesProc.generation)
    }
  }

  Process {
    id: stationsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.stationsLoading = false
        var raw = String(text || "").trim()
        if (raw === "") {
          console.warn("[mbta] station list fetch returned nothing")
          return
        }
        try {
          var parsed = JSON.parse(raw)
          root.stationsCache = Array.isArray(parsed.data) ? parsed.data.slice(0, 10000) : []
        } catch (e) {
          console.warn("[mbta] station list parse failed:", e.message)
        }
      }
    }
  }

  Process {
    id: weatherLocationProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.weatherLocationState = Mbta.parseWeatherLocation(text)
    }
  }

  Timer {
    id: tickTimer
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  // Read the small cross-plugin location file through a no-follow, regular-file
  // adapter instead of retaining an arbitrary FileView body in the shell.
  Timer {
    interval: 1500
    running: true
    onTriggered: {
      weatherLocationProc.command = [root.weatherReader,
        Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"]
      weatherLocationProc.running = true
    }
  }

  function readSetting(name, fallback) {
    return setting(name, fallback)
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locating = false
        var hits = Mbta.parseGeocoding(text)
        if (!hits.length) {
          root.nearbyError = "Address not found"
          return
        }
        fetchNearby(hits[0].latitude, hits[0].longitude, root.pendingRadiusKm, hits[0].name)
      }
    }
  }

  Process {
    id: ipLocProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locating = false
        var coords = Mbta.parseIpLoc(text)
        if (!coords) {
          root.pendingNearbyAfterLocate = false
          root.nearbyError = "Could not detect location"
          return
        }
        root.ipLocation = coords
        if (root.pendingNearbyAfterLocate) {
          root.pendingNearbyAfterLocate = false
          fetchNearby(coords.latitude, coords.longitude, root.pendingRadiusKm, "IP location")
        }
      }
    }
  }

  Process {
    id: nearbyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.nearbyLoading = false
        var raw = String(text || "").trim()
        if (raw === "" || !root.lastOrigin) {
          root.nearbyResults = []
          return
        }
        try {
          var payload = JSON.parse(raw)
          root.nearbyResults = Mbta.collectNearbyStops(
            payload, root.lastOrigin.latitude, root.lastOrigin.longitude)
          if (root.nearbyResults.length === 0) root.nearbyError = "No stations found in that radius"
        } catch (e) {
          root.nearbyError = "MBTA response error"
        }
      }
    }
  }

  Process {
    id: lineStopsProc
    property int generation: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (lineStopsProc.generation !== root.lineGeneration) return
        var raw = String(text || "").trim()
        if (root.activeLineKey === "") return
        try {
          root.lineStops = Mbta.parseLineStops(JSON.parse(raw), root.activeLineDirectionId)
          if (!root.lineStops.length) {
            root.lineError = "No route stops found"
            root.lineLoading = false
            return
          }
          root.refreshLineVehicles()
        } catch (e) {
          root.lineLoading = false
          root.lineError = "Could not load route stops"
        }
      }
    }
  }

  Process {
    id: lineVehiclesProc
    property int generation: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (lineVehiclesProc.generation !== root.lineGeneration) return
        if (root.activeLineKey === "") return
        var raw = String(text || "").trim()
        try {
          root.lineVehicles = Mbta.parseVehicles(JSON.parse(raw), root.lineStops)
          root.lineError = ""
        } catch (e) {
          root.lineError = "Live vehicles unavailable"
        }
        root.lineLoading = false
      }
    }
  }

  Timer {
    interval: 20000
    running: root.activeLineKey !== ""
    repeat: true
    onTriggered: root.refreshLineVehicles()
  }

  // ---- Panel lifecycle plumbing (shape contract for summon/hide routing).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
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

  // WidgetButton's default width only accounts for one icon. Reserve the
  // custom icon-and-countdown row so the next bar module cannot overlap it.
  implicitWidth: contentRow.implicitWidth + Style.space(14)
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
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

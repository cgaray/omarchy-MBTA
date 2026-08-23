import QtQuick

// Nonvisual station-picker session. The panel translates focusIntent into
// concrete controls; this module owns all picker state and transitions.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  property var feed: null
  property var preferences: null
  property bool managing: false
  property string pickerMode: "name"
  property string stationQuery: ""
  property var stationResults: []
  property int resultIndex: -1
  property string addressText: ""
  property string radiusText: "1"
  readonly property bool stationsReady: !!root.feed && root.feed.stationsCache !== null

  signal focusIntent(string target)

  Timer {
    id: searchDebounce
    interval: 120
    onTriggered: root.runStationSearch()
  }

  onStationsReadyChanged: {
    if (root.managing && root.pickerMode === "name" && root.stationQuery !== "")
      searchDebounce.restart()
  }

  Component.onCompleted: {
    if (!root.preferences) return
    root.pickerMode = root.preferences.pickerMode
    root.addressText = root.preferences.location
    root.radiusText = String(root.preferences.lastRadiusKm)
  }

  function resetResults() {
    root.stationQuery = ""
    root.stationResults = []
    root.resultIndex = -1
    searchDebounce.stop()
  }

  function requestPickerFocus() {
    root.focusIntent(root.pickerMode === "name" ? "station" : "address")
  }

  function startManaging() {
    root.managing = true
    if (root.preferences) {
      root.pickerMode = root.preferences.pickerMode
      root.addressText = root.preferences.location
      root.radiusText = String(root.preferences.lastRadiusKm)
    }
    root.resetResults()
    root.requestPickerFocus()
  }

  function stopManaging() {
    root.managing = false
    root.resetResults()
    root.focusIntent("panel")
  }

  function setPickerMode(mode) {
    var normalized = String(mode || "") === "nearby" ? "nearby" : "name"
    if (root.pickerMode === normalized) return
    root.pickerMode = normalized
    root.resetResults()
    if (root.preferences) root.preferences.setPickerMode(normalized)
    root.requestPickerFocus()
  }

  function setStationQuery(query) {
    root.stationQuery = String(query || "")
    searchDebounce.restart()
  }

  function clearStationQuery() {
    root.stationQuery = ""
    searchDebounce.restart()
  }

  function runStationSearch() {
    if (!root.feed) return
    if (root.stationQuery.trim() !== "" && root.feed.stationsCache === null) {
      root.feed.ensureStations()
      return
    }
    root.stationResults = root.feed.searchStations(root.stationQuery)
    root.resultIndex = root.stationResults.length > 0 ? 0 : -1
  }

  function parseRadius(text) {
    var radiusKm = root.preferences ? root.preferences.normalizeRadius(text) : parseFloat(String(text).replace(",", "."))
    if (isNaN(radiusKm) || radiusKm <= 0) radiusKm = 1
    radiusKm = Math.min(20, radiusKm)
    root.radiusText = String(radiusKm)
    return radiusKm
  }

  function triggerNearbySearch() {
    if (!root.feed) return false
    var address = root.addressText
    var radiusKm = root.parseRadius(root.radiusText)
    var started = root.feed.findNearby(address, radiusKm)
    if (started && root.preferences) root.preferences.rememberNearby(address, radiusKm)
    return started
  }

  function useSavedLocation() {
    if (!root.feed || !root.preferences) return false
    var location = root.preferences.location
    root.addressText = location
    var radiusKm = root.parseRadius(root.radiusText)
    var started = root.feed.findNearby(location, radiusKm)
    if (started) root.preferences.rememberRadius(radiusKm)
    return started
  }

  function activeResultCount() {
    return root.pickerMode === "name" ? root.stationResults.length
      : (root.feed ? root.feed.nearbyResults.length : 0)
  }

  function pickResult(at) {
    if (!root.feed || !root.preferences || at < 0 || at >= root.activeResultCount()) return
    var stationId = root.pickerMode === "name"
      ? root.stationResults[at].id : root.feed.nearbyResults[at].id
    if (root.preferences.toggleStop(stationId) && root.feed.refreshNow)
      Qt.callLater(root.feed.refreshNow)
    if (root.pickerMode === "name") searchDebounce.restart()
  }

  function toggleStop(stationId) {
    if (!root.preferences || !root.preferences.toggleStop(stationId)) return
    if (root.feed && root.feed.refreshNow) Qt.callLater(root.feed.refreshNow)
  }

  function togglePinnedLine() {
    if (root.preferences && root.feed)
      root.preferences.togglePinnedLine(root.feed.activeLinePinKey)
  }

  function moveResultSelection(delta) {
    var count = root.activeResultCount()
    if (!count) return
    root.resultIndex = Math.max(0, Math.min(count - 1, root.resultIndex + delta))
  }
}

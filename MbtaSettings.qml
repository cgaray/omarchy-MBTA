import QtQuick
import "Mbta.js" as Mbta

// Always-mounted settings boundary. The host adapter is deliberately limited
// to applying one complete module entry; parsing and mutations stay here.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  required property var ownerAdapter
  property var source: ({})

  readonly property var configuredStopIds: Mbta.parseStopIds(value("stopIds", Mbta.serializeStopIds(Mbta.DEFAULT_STOP_IDS)))
  readonly property int refreshSec: boundedInteger(value("refreshSec", 60), 60, 60, 300)
  readonly property int perGroupCap: boundedInteger(value("perGroupCap", 3), 3, 1, 3)
  readonly property bool scheduleFallback: value("scheduleFallback", true) !== false
  readonly property string pinnedLineKey: String(value("pinnedLine", "") || "").slice(0, 300)
  readonly property string pickerMode: normalizePickerMode(value("pickerMode", "name"))
  // Keep the existing storage key so released installations retain their value.
  readonly property string location: String(value("lastAddress", "") || "").slice(0, 200)
  readonly property real lastRadiusKm: normalizeRadius(value("lastRadiusKm", 1))

  function value(name, fallback) {
    if (!root.source || root.source[name] === undefined || root.source[name] === null)
      return fallback
    return root.source[name]
  }

  function boundedInteger(raw, fallback, minimum, maximum) {
    var parsed = parseInt(raw, 10)
    if (isNaN(parsed)) parsed = fallback
    return Math.max(minimum, Math.min(maximum, parsed))
  }

  function normalizePickerMode(raw) {
    return String(raw || "") === "nearby" ? "nearby" : "name"
  }

  function normalizeRadius(raw) {
    var parsed = parseFloat(String(raw === undefined || raw === null ? "" : raw).replace(",", "."))
    if (isNaN(parsed) || parsed <= 0) parsed = 1
    return Math.min(20, parsed)
  }

  function normalize(name, raw) {
    switch (name) {
    case "stopIds": return Mbta.serializeStopIds(Mbta.parseStopIds(raw))
    case "refreshSec": return root.boundedInteger(raw, 60, 60, 300)
    case "perGroupCap": return root.boundedInteger(raw, 3, 1, 3)
    case "scheduleFallback": return raw !== false
    case "pinnedLine": return String(raw || "").slice(0, 300)
    case "pickerMode": return root.normalizePickerMode(raw)
    case "lastAddress": return String(raw || "").slice(0, 200)
    case "lastRadiusKm": return root.normalizeRadius(raw)
    default: return raw
    }
  }

  function update(patch) {
    var entry = Mbta.dictionary()
    var key
    // Own properties only: for..in walks the prototype chain, and a polluted
    // Object.prototype must never be swept into the persisted settings entry.
    for (key in root.source)
      if (key !== "id" && Object.prototype.hasOwnProperty.call(root.source, key))
        entry[key] = root.source[key]
    for (key in patch) {
      if (!Object.prototype.hasOwnProperty.call(patch, key)) continue
      entry[key] = root.normalize(key, patch[key])
    }

    // The owner applies this synchronously before shell.json echoes it back.
    root.ownerAdapter.applySettingsEntry(entry)
    return entry
  }

  function setStopIds(ids) {
    root.update({ stopIds: Mbta.serializeStopIds(ids) })
  }

  function toggleStop(id) {
    var stationId = String(id || "")
    if (stationId === "") return false
    var ids = root.configuredStopIds.slice()
    var at = ids.indexOf(stationId)
    if (at >= 0) ids.splice(at, 1)
    else ids.push(stationId)
    root.setStopIds(ids)
    return true
  }

  function togglePinnedLine(activeLinePinKey) {
    var key = String(activeLinePinKey || "").slice(0, 300)
    if (key === "") return false
    root.update({ pinnedLine: root.pinnedLineKey === key ? "" : key })
    return true
  }

  function setPickerMode(mode) {
    root.update({ pickerMode: mode })
  }

  function rememberNearby(address, radiusKm) {
    root.update({ lastAddress: address, lastRadiusKm: radiusKm, pickerMode: "nearby" })
  }

  function rememberRadius(radiusKm) {
    root.update({ lastRadiusKm: radiusKm, pickerMode: "nearby" })
  }
}

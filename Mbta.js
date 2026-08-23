// Pure data seam for the MBTA plugin.
//
// Plain ES5-compatible JavaScript with no QML/Quickshell imports so it can be
// unit-tested in Node (see tests/mbta-test.js). Views import this file; this
// file imports nothing. All times crossing this seam are epoch milliseconds.

var API_BASE = "https://api-v3.mbta.com"

// Downtown Boston stations: a useful out-of-the-box "near me" set. Users
// override through the stopIds setting or the in-panel station picker.
var DEFAULT_STOP_IDS = [
  "place-dwnxg",
  "place-pktrm",
  "place-gover",
  "place-haecl",
  "place-sstat"
]

// MBTA service type colors, used when a route ships no color of its own.
var TYPE_FALLBACK_COLORS = {
  0: "00843D", // light rail / Green Line
  1: "DA291C", // heavy rail / subway
  2: "80276C", // commuter rail
  3: "FFC72C", // bus / silver line
  4: "008EAA"  // ferry
}

function boundedText(value, maxLength) {
  return String(value === undefined || value === null ? "" : value).slice(0, maxLength)
}

function boundedList(value, maxLength) {
  return Array.isArray(value) ? value.slice(0, maxLength) : []
}

function dictionary() {
  return Object.create(null)
}

function parseStopIds(raw) {
  var seen = dictionary()
  var out = []
  var parts = boundedText(raw, 1620).split(",")
  for (var i = 0; i < parts.length && out.length < 20; i++) {
    var id = parts[i].replace(/^\s+|\s+$/g, "")
    if (!/^[A-Za-z0-9._:-]{1,80}$/.test(id) || seen[id]) continue
    seen[id] = true
    out.push(id)
  }
  return out
}

function serializeStopIds(ids) {
  return (ids || []).join(",")
}

function predictionsUrl(stopIds) {
  return API_BASE + "/predictions"
    + "?filter%5Bstop%5D=" + encodeURIComponent(serializeStopIds(stopIds))
    + "&sort=time"
    + "&include=route,trip,stop"
    + "&fields%5Bprediction%5D=arrival_time,departure_time,direction_id,status,route,trip,stop"
    + "&fields%5Broute%5D=color,long_name,short_name,text_color,type"
    + "&fields%5Btrip%5D=headsign"
    + "&fields%5Bstop%5D=name,parent_station"
}

// minTime/maxTime are local "HH:MM" strings the caller computes around now;
// schedules have no predictions to lean on, so the window keeps the payload small.
function schedulesUrl(stopIds, serviceDate, minTime, maxTime) {
  return API_BASE + "/schedules"
    + "?filter%5Bstop%5D=" + encodeURIComponent(serializeStopIds(stopIds))
    + "&filter%5Bdate%5D=" + encodeURIComponent(String(serviceDate))
    + "&filter%5Bmin_time%5D=" + encodeURIComponent(String(minTime || "00:00"))
    + "&filter%5Bmax_time%5D=" + encodeURIComponent(String(maxTime || "23:59"))
    + "&sort=time"
    + "&include=route,trip,stop"
    + "&fields%5Bschedule%5D=arrival_time,departure_time,direction_id,route,trip,stop"
    + "&fields%5Broute%5D=color,long_name,short_name,text_color,type"
    + "&fields%5Btrip%5D=headsign"
    + "&fields%5Bstop%5D=name,parent_station"
}

function stationsUrl() {
  // Rail stations (location_type 1) plus street bus stops (0), slimmed with
  // sparse fieldsets — the full attribute set runs 4.4MB; this trims it to
  // roughly half. Fetched once per session and cached for the picker.
  return API_BASE + "/stops"
    + "?filter%5Blocation_type%5D=0,1"
    + "&fields%5Bstop%5D=name,municipality,parent_station"
}

// ---- Strip map (tap a line row to see the route with live vehicles) ----

// Ordered stops for one direction of a route.
function lineStopsUrl(tripId) {
  return API_BASE + "/trips/" + encodeURIComponent(boundedText(tripId, 100))
    + "?include=stops"
    + "&fields%5Btrip%5D=stops"
    + "&fields%5Bstop%5D=name,parent_station"
}

function vehiclesUrl(routeId, directionId) {
  return API_BASE + "/vehicles"
    + "?filter%5Broute%5D=" + encodeURIComponent(String(routeId))
    + "&filter%5Bdirection_id%5D=" + encodeURIComponent(String(directionId))
    + "&include=stop"
    + "&page%5Blimit%5D=200"
    + "&fields%5Bvehicle%5D=current_status,label,stop,trip"
    + "&fields%5Bstop%5D=parent_station"
}

function parseLineStops(payload) {
  var included = boundedList(payload && payload.included, 1000)
  var stopsById = dictionary()
  for (var i = 0; i < included.length; i++) {
    var includedStop = included[i]
    if (includedStop && includedStop.type === "stop" && includedStop.id)
      stopsById[includedStop.id] = includedStop
  }
  var relationships = payload && payload.data && payload.data.relationships
  var stopRefs = boundedList(relationships && relationships.stops
    && relationships.stops.data, 500)
  var out = []
  for (var s = 0; s < stopRefs.length; s++) {
    var stop = stopsById[stopRefs[s].id]
    if (!stop || !stop.id || !stop.attributes) continue
    var name = boundedText(stop.attributes.name, 160)
    if (name === "") continue
    var parent = stop.relationships && stop.relationships.parent_station
      && stop.relationships.parent_station.data
    var id = parent && parent.id ? String(parent.id) : String(stop.id)
    if (!out.length || out[out.length - 1].id !== id) out.push({ id: id, name: name })
  }
  return out
}

// Map vehicles onto the strip: a 0..1 fraction of the line's length.
// STOPPED_AT sits on its stop's dot; INCOMING_AT / IN_TRANSIT_TO ride
// halfway toward the stop they are approaching. Rail vehicles target platform
// ids, so included stops map those children back to route-level stations.
function parseVehicles(payload, orderedStops) {
  var data = boundedList(payload && payload.data, 200)
  var count = orderedStops.length
  if (!count) return []

  var indexById = dictionary()
  for (var s = 0; s < count; s++) indexById[orderedStops[s].id] = s

  var parentByStop = dictionary()
  var included = boundedList(payload && payload.included, 500)
  for (var p = 0; p < included.length; p++) {
    var includedStop = included[p]
    if (!includedStop || includedStop.type !== "stop") continue
    var parentRel = includedStop.relationships && includedStop.relationships.parent_station
    if (parentRel && parentRel.data && parentRel.data.id)
      parentByStop[String(includedStop.id)] = String(parentRel.data.id)
  }

  var byTrip = dictionary()
  var out = []
  for (var i = 0; i < data.length; i++) {
    var v = data[i]
    if (!v || !v.attributes) continue
    var attrs = v.attributes
    var status = String(attrs.current_status || "")

    var stopRel = v.relationships && v.relationships.stop && v.relationships.stop.data
    var rawStopId = stopRel && stopRel.id ? String(stopRel.id) : String(attrs.stop_id || "")
    var routeStopId = parentByStop[rawStopId] || rawStopId
    var seq = indexById[routeStopId]
    if (seq === undefined) continue

    var fraction
    if (status === "STOPPED_AT") {
      fraction = count === 1 ? 0 : seq / (count - 1)
    } else if (status === "INCOMING_AT" || status === "IN_TRANSIT_TO") {
      var base = Math.max(0, seq - 1)
      fraction = count === 1 ? 0 : (base + 0.5) / (count - 1)
    } else {
      continue
    }
    if (fraction < 0) fraction = 0
    if (fraction > 1) fraction = 1

    var entry = {
      id: String(v.id),
      fraction: fraction,
      status: status,
      stopId: routeStopId,
      label: String(attrs.label || "")
    }
    // One vehicle per trip id; keep whichever reports the freshest position
    // (later entries win, matching sort order upstream).
    var tripKey = v.relationships && v.relationships.trip && v.relationships.trip.data
      ? String(v.relationships.trip.data.id) : entry.id
    if (byTrip[tripKey] !== undefined) out[byTrip[tripKey]] = entry
    else {
      byTrip[tripKey] = out.length
      out.push(entry)
    }
  }
  out.sort(function(a, b) { return a.fraction - b.fraction })
  return out
}

// included[] → { route: {id: obj}, trip: {id: obj}, stop: {id: obj} }
function indexIncluded(included) {
  var index = { route: dictionary(), trip: dictionary(), stop: dictionary() }
  var list = boundedList(included, 3000)
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || !entry.id || !entry.type) continue
    if (!index[entry.type]) continue
    index[entry.type][entry.id] = entry
  }
  return index
}

// Rough WCAG-ish contrast pick for badge text over a hex background.
function readableTextColor(hex) {
  var value = String(hex || "").replace("#", "")
  if (!/^[0-9a-fA-F]{6}$/.test(value)) return "FFFFFF"
  var r = parseInt(value.slice(0, 2), 16)
  var g = parseInt(value.slice(2, 4), 16)
  var b = parseInt(value.slice(4, 6), 16)
  var luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
  return luminance > 140 ? "1B1B1B" : "FFFFFF"
}

// Badge label for a route: short names win ("B", "SL1"), color words come
// next ("Red"), commuter rail collapses to "CR".
function routeBadgeLabel(route) {
  if (!route) return "?"
  var attrs = route.attributes || {}
  var shortName = String(attrs.short_name || "").replace(/^\s+|\s+$/g, "")
  if (shortName !== "") return shortName

  var longName = String(attrs.long_name || "").replace(/^\s+|\s+$/g, "")
  var colorWord = longName.replace(/\s*Line\s*$/, "")
  if (/^(Red|Orange|Blue|Green|Silver)$/.test(colorWord)) return colorWord

  var type = parseInt(String(attrs.type), 10)
  if (type === 2) return "CR"
  if (type === 4) return "BOAT"
  if (longName !== "") return longName.split(/[\s\/-]+/)[0].slice(0, 4)
  return String(route.id || "?")
}

function routeBadge(route) {
  if (!route) return { label: "?", color: TYPE_FALLBACK_COLORS[3], textColor: "FFFFFF" }
  var attrs = route.attributes || {}
  var color = String(attrs.color || "").toUpperCase()
  if (!/^[0-9A-F]{6}$/.test(color)) {
    color = TYPE_FALLBACK_COLORS[parseInt(String(attrs.type), 10)] || TYPE_FALLBACK_COLORS[3]
  }
  // The API's declared text color wins when present; contrast-pick only as
  // a fallback for routes that ship no pairing.
  var textColor = String(attrs.text_color || "").toUpperCase()
  if (!/^[0-9A-F]{6}$/.test(textColor)) textColor = readableTextColor(color)
  return {
    label: routeBadgeLabel(route),
    color: color,
    textColor: textColor
  }
}

// The API's included[] lists platform child stops (70078), never the parent
// stations users configure (place-dwnxg). Harvest display names for both:
// parent ids from their platforms, and top-level ids (street bus stops)
// directly, since those appear in included[] themselves.
function parentStationMap(stopIndex) {
  var names = dictionary()
  for (var id in stopIndex.stop) {
    var stop = stopIndex.stop[id]
    if (!stop || !stop.attributes || !stop.attributes.name) continue

    var rel = stop && stop.relationships && stop.relationships.parent_station
    if (!rel || !rel.data || !rel.data.id) {
      if (!names[id]) names[id] = String(stop.attributes.name)
      continue
    }
    var parentId = String(rel.data.id)
    if (!names[parentId]) names[parentId] = String(stop.attributes.name)
  }
  return names
}

// Predictions point at platform child stops; configured stops are usually
// parent stations. Climb one parent hop when needed.
function resolveConfiguredStopId(stopRelId, stopIndex, configuredSet, parentNames) {
  var id = String(stopRelId || "")
  if (configuredSet[id]) return id
  var stop = stopIndex.stop[id]
  var rel = stop && stop.relationships && stop.relationships.parent_station
  var parent = rel && rel.data ? String(rel.data.id) : ""
  if (parent !== "" && configuredSet[parent]) return parent
  // Last resort: some platforms ship without relationship data but share a name.
  var name = stop && stop.attributes ? String(stop.attributes.name || "") : ""
  if (name !== "" && parentNames) {
    for (var pid in parentNames) {
      if (configuredSet[pid] && parentNames[pid] === name) return pid
    }
  }
  return null
}

function rowTimeMs(attributes) {
  var arrival = attributes ? attributes.arrival_time : null
  var departure = attributes ? attributes.departure_time : null
  var iso = arrival || departure
  if (!iso) return NaN
  var ms = new Date(iso).getTime()
  return isNaN(ms) ? NaN : ms
}

// One candidate train. Rows keep everything the board needs except grouping.
function collectRows(payload, nowMs, realtime) {
  if (!payload || !payload.data) return []
  var index = indexIncluded(payload.included)
  var rows = []
  var data = boundedList(payload.data, 1000)
  for (var i = 0; i < data.length; i++) {
    var entry = data[i]
    if (!entry || entry.type !== (realtime ? "prediction" : "schedule")) continue
    var attrs = entry.attributes || {}
    var timeMs = rowTimeMs(attrs)
    if (isNaN(timeMs)) continue
    // Only future departures belong on the board.
    if (timeMs < nowMs) continue

    var rel = entry.relationships || {}
    var routeRel = rel.route && rel.route.data ? rel.route.data.id : null
    var tripRel = rel.trip && rel.trip.data ? rel.trip.data.id : null
    var stopRel = rel.stop && rel.stop.data ? rel.stop.data.id : null
    if (!routeRel || !stopRel) continue

    var trip = tripRel ? index.trip[tripRel] : null
    var headsign = trip && trip.attributes && trip.attributes.headsign
      ? boundedText(trip.attributes.headsign, 120) : ""

    rows.push({
      routeId: boundedText(routeRel, 80),
      tripId: tripRel ? boundedText(tripRel, 100) : "",
      stopId: boundedText(stopRel, 80),
      headsign: headsign,
      directionId: attrs.direction_id === undefined ? -1 : Number(attrs.direction_id),
      timeMs: timeMs,
      status: attrs.status ? boundedText(attrs.status, 40) : "",
      realtime: realtime
    })
  }
  rows.sort(function(a, b) { return a.timeMs - b.timeMs })
  return rows
}

// Boards read cleanest without special-casing departures that are at the
// platform: everything counts down 2m → 1m and leaves.
function countdownLabel(diffMs) {
  var minutes = Math.ceil(diffMs / 60000)
  if (minutes < 1) minutes = 1
  if (minutes > 90) return ""
  return minutes + "m"
}

function groupKey(row) {
  return [row.routeId, String(row.directionId), row.headsign].join("|")
}

// rows must already carry resolvedConfiguredStopId. Output is ordered by each
// group's first departure; times inside a group are capped and labeled here.
function buildBoard(rows, stopIndex, configuredIds, nowMs, cap) {
  var configuredSet = dictionary()
  for (var c = 0; c < configuredIds.length; c++) configuredSet[configuredIds[c]] = true
  var parentNames = parentStationMap(stopIndex)

  var limit = Math.max(1, cap || 3)
  var byStop = dictionary()
  for (var s = 0; s < configuredIds.length; s++) {
    byStop[configuredIds[s]] = []
  }

  var overflow = dictionary()
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row || row.timeMs < nowMs) continue
    var stopId = resolveConfiguredStopId(row.stopId, stopIndex, configuredSet, parentNames)
    if (!stopId) continue
    row.configuredStopId = stopId
    var groups = byStop[stopId]
    var key = groupKey(row)
    var group = null
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].key === key) { group = groups[g]; break }
    }
    if (!group) {
      var route = stopIndex.route[row.routeId]
      group = {
        key: key,
        stopId: stopId,
        routeId: row.routeId,
        directionId: row.directionId,
        tripId: row.tripId,
        headsign: row.headsign,
        badge: routeBadge(route),
        routeType: route && route.attributes ? parseInt(String(route.attributes.type), 10) : -1,
        realtime: row.realtime,
        times: []
      }
      groups.push(group)
    }
    if (group.times.length < limit) {
      group.times.push({
        ms: row.timeMs,
        label: countdownLabel(row.timeMs - nowMs),
        status: row.status
      })
    } else {
      overflow[key] = (overflow[key] || 0) + 1
    }
  }

  var stops = []
  var nextMs = NaN
  var nextLabel = ""
  for (var n = 0; n < configuredIds.length; n++) {
    var id = configuredIds[n]
    var stopGroups = byStop[id]
    stopGroups.sort(function(a, b) {
      var at = a.times.length ? a.times[0].ms : Infinity
      var bt = b.times.length ? b.times[0].ms : Infinity
      return at - bt
    })
    for (var k = 0; k < stopGroups.length; k++) {
      stopGroups[k].more = overflow[stopGroups[k].key] || 0
      if (stopGroups[k].times.length) {
        // Bar label wants the soonest departure across every configured stop,
        // not merely the first stop that happens to have service.
        if (isNaN(nextMs) || stopGroups[k].times[0].ms < nextMs) {
          nextMs = stopGroups[k].times[0].ms
          nextLabel = stopGroups[k].times[0].label
        }
      }
      // A group whose every departure fell into the hidden overflow adds nothing.
      if (!stopGroups[k].times.length) stopGroups.splice(k--, 1)
    }
    stops.push({
      id: id,
      name: stopNameFor(id, parentNames),
      groups: stopGroups
    })
  }

  return {
    generatedAtMs: nowMs,
    realtime: rows.length === 0 || rows[0].realtime,
    stops: stops,
    nextMs: nextMs,
    nextLabel: nextLabel
  }
}

function linePinKey(group) {
  if (!group) return ""
  return String(group.stopId || "") + "|" + String(group.key || "")
}

function pinnedNextLabel(board, pinKey, nowMs) {
  var key = String(pinKey || "")
  if (!board || key === "") return ""
  var stops = board.stops || []
  for (var s = 0; s < stops.length; s++) {
    var groups = stops[s].groups || []
    for (var g = 0; g < groups.length; g++) {
      if (linePinKey(groups[g]) === key) {
        if (!groups[g].times || !groups[g].times.length) return ""
        return nowMs === undefined
          ? String(groups[g].times[0].label || "")
          : countdownLabel(groups[g].times[0].ms - nowMs)
      }
    }
  }
  return ""
}

function stopNameFor(id, parentNames) {
  if (parentNames && parentNames[id]) return parentNames[id]
  return id
}

// MBTA service days run past midnight using 24:xx..27:xx clock values.
function scheduleWindow(nowDate) {
  function pad(n) { return (n < 10 ? "0" : "") + n }
  function dayNumber(d) { return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / 86400000 }
  function dateStamp(d) {
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
  }
  var serviceDate = new Date(nowDate.getFullYear(), nowDate.getMonth(), nowDate.getDate())
  if (nowDate.getHours() < 3) serviceDate.setDate(serviceDate.getDate() - 1)
  function stamp(d) {
    var hour = (dayNumber(d) - dayNumber(serviceDate)) * 24 + d.getHours()
    return pad(hour) + ":" + pad(d.getMinutes())
  }
  // The extra five minutes cover the coordinator's schedule-cache lifetime,
  // preserving a full two-hour horizon at the oldest valid cache hit.
  var end = new Date(nowDate.getTime() + 125 * 60000)
  return { date: dateStamp(serviceDate), min: stamp(nowDate), max: stamp(end) }
}

// Station picker search over the cached stop list (rail stations AND street
// bus stops). Prefix matches rank above word-start matches, which rank above
// substrings. Duplicate names collapse to one row: platforms share their
// station's name, so prefer top-level representatives, then place-* ids.
function dedupeStops(dataList) {
  var best = dictionary()
  var list = boundedList(dataList, 10000)
  for (var i = 0; i < list.length; i++) {
    var stop = list[i]
    if (!stop || !stop.id) continue
    var attrs = stop.attributes || stop
    var name = boundedText(attrs.name, 160)
    if (name === "") continue

    var parentData = stop.relationships && stop.relationships.parent_station
      && stop.relationships.parent_station.data
    var candidate = {
      id: boundedText(stop.id, 80),
      name: name,
      municipality: attrs.municipality ? boundedText(attrs.municipality, 120) : "",
      rank: (!parentData || !parentData.id ? 0 : 8)
        + (String(stop.id).indexOf("place-") === 0 ? 0 : 1)
    }

    var key = name.toLowerCase() + "\u0001" + candidate.municipality.toLowerCase()
    var incumbent = best[key]
    if (!incumbent || candidate.rank < incumbent.rank) best[key] = candidate
  }

  var out = []
  for (var k in best) out.push(best[k])
  return out
}

function filterStations(dataList, query, limit) {
  var q = boundedText(query, 120).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (q === "") return []

  var results = []
  var unique = dedupeStops(dataList)
  for (var i = 0; i < unique.length; i++) {
    var entry = unique[i]
    var lower = entry.name.toLowerCase()
    var score = -1
    if (lower.indexOf(q) === 0) score = 0
    else {
      var wordStart = lower.search(new RegExp("(^|\\s)" + escapeRegExp(q)))
      if (wordStart >= 0) score = 1
      else if (lower.indexOf(q) >= 0) score = 2
    }
    if (score < 0) continue
    entry.score = score
    results.push(entry)
  }
  results.sort(function(a, b) {
    if (a.score !== b.score) return a.score - b.score
    if (a.name !== b.name) return a.name < b.name ? -1 : 1
    return a.id < b.id ? -1 : 1
  })
  return results.slice(0, Math.max(1, limit || 20))
}

function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// ---- Nearby-station search -------------------------------------------------
//
// Origin comes from raw "lat,lon" typed by the user or an IP lookup.
// The MBTA geo endpoint takes its radius in degrees; users think in km.

function parseLatLon(text) {
  var match = String(text === undefined || text === null ? "" : text)
    .replace(/^\s+|\s+$/g, "")
    .match(/^(-?\d{1,2}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)$/)
  if (!match) return null
  var latitude = parseFloat(match[1])
  var longitude = parseFloat(match[2])
  if (isNaN(latitude) || isNaN(longitude)) return null
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null
  return { latitude: latitude, longitude: longitude }
}

function radiusDegrees(km) {
  var value = parseFloat(km)
  if (isNaN(value) || value <= 0) value = 1
  // Degrees latitude; clamped so a typo cannot query the whole planet.
  return Math.min(20 / 111.32, Math.max(0.001, value / 111.32))
}

function haversineMeters(lat1, lon1, lat2, lon2) {
  var radius = 6371000
  var rad = Math.PI / 180
  var dLat = (lat2 - lat1) * rad
  var dLon = (lon2 - lon1) * rad
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(lat1 * rad) * Math.cos(lat2 * rad)
      * Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return Math.round(2 * radius * Math.asin(Math.min(1, Math.sqrt(a))))
}

function formatDistance(meters) {
  var m = parseFloat(meters)
  if (isNaN(m) || m < 0) return ""
  if (m < 950) return Math.round(m) + " m"
  return (Math.round(m / 100) / 10) + " km"
}

function nearbyUrl(latitude, longitude, radiusKm) {
  return API_BASE + "/stops"
    + "?filter%5Blatitude%5D=" + encodeURIComponent(String(latitude))
    + "&filter%5Blongitude%5D=" + encodeURIComponent(String(longitude))
    + "&filter%5Bradius%5D=" + encodeURIComponent(String(radiusDegrees(radiusKm)))
    + "&filter%5Blocation_type%5D=0,1"
    + "&sort=distance"
    + "&page%5Blimit%5D=500"
    + "&fields%5Bstop%5D=name,municipality,latitude,longitude,location_type,parent_station"
}

// Address → coordinates via OpenStreetMap's Nominatim (free, no key; usage
// policy asks for an identifying User-Agent, which curl sends as -A).
function geocodeUrl(query) {
  return "https://nominatim.openstreetmap.org/search"
    + "?format=jsonv2&limit=3&q=" + encodeURIComponent(boundedText(query, 200))
}

// Nominatim display_name is a long address; keep the leading parts humans say.
function shortPlaceName(displayName) {
  var parts = boundedText(displayName, 400).split(",").map(function(p) { return p.replace(/^\s+|\s+$/g, "") })
  parts = parts.filter(function(p) { return p !== "" })
  return parts.slice(0, 2).join(", ")
}

function parseGeocoding(raw) {
  try {
    var list = JSON.parse(String(raw || "[]"))
    if (!list || !list.length) return []
    var out = []
    for (var i = 0; i < list.length && out.length < 3; i++) {
      var hit = list[i]
      if (!hit) continue
      var latitude = parseFloat(hit.lat)
      var longitude = parseFloat(hit.lon)
      if (isNaN(latitude) || isNaN(longitude)) continue
      out.push({
        name: shortPlaceName(hit.display_name),
        latitude: latitude,
        longitude: longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Geo results mix parent stations, platforms, bus stops, and interior
// "door"/"node" entries. Keep stations and street stops, collapse platforms
// into their parent station id, and score each by distance to the origin.
function collectNearbyStops(payload, originLat, originLon) {
  var data = boundedList(payload && payload.data, 2000)
  var byKey = dictionary()
  for (var i = 0; i < data.length; i++) {
    var stop = data[i]
    if (!stop || !stop.id || !stop.attributes) continue

    var typeRaw = stop.attributes.location_type
    var locationType = (typeRaw === undefined || typeRaw === null) ? 0 : parseInt(String(typeRaw), 10)
    if (!(locationType === 0 || locationType === 1)) continue

    var lat = parseFloat(stop.attributes.latitude)
    var lon = parseFloat(stop.attributes.longitude)
    if (isNaN(lat) || isNaN(lon)) continue

    var rel = stop.relationships && stop.relationships.parent_station && stop.relationships.parent_station.data
      ? String(stop.relationships.parent_station.data.id) : ""
    var key = rel !== "" ? rel : String(stop.id)
    var entry = {
      id: boundedText(key, 80),
      name: boundedText(stop.attributes.name, 160),
      municipality: boundedText(stop.attributes.municipality, 120),
      latitude: lat,
      longitude: lon,
      distanceMeters: haversineMeters(originLat, originLon, lat, lon),
      isStation: locationType === 1 && rel === ""
    }

    var existing = byKey[key]
    if (!existing) {
      byKey[key] = entry
    } else if (entry.isStation) {
      // The canonical station object wins the identity; keep the closer of
      // the two positions for the reported distance.
      entry.distanceMeters = Math.min(existing.distanceMeters, entry.distanceMeters)
      byKey[key] = entry
    } else {
      existing.distanceMeters = Math.min(existing.distanceMeters, entry.distanceMeters)
    }
  }

  var out = []
  for (var k in byKey) out.push(byKey[k])
  out.sort(function(a, b) {
    if (a.distanceMeters !== b.distanceMeters) return a.distanceMeters - b.distanceMeters
    if (a.name !== b.name) return a.name < b.name ? -1 : 1
    return a.id < b.id ? -1 : 1
  })
  return out.slice(0, 100)
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_STOP_IDS: DEFAULT_STOP_IDS,
    dictionary: dictionary,
    parseStopIds: parseStopIds,
    serializeStopIds: serializeStopIds,
    predictionsUrl: predictionsUrl,
    schedulesUrl: schedulesUrl,
    stationsUrl: stationsUrl,
    lineStopsUrl: lineStopsUrl,
    vehiclesUrl: vehiclesUrl,
    parseLineStops: parseLineStops,
    parseVehicles: parseVehicles,
    indexIncluded: indexIncluded,
    parentStationMap: parentStationMap,
    readableTextColor: readableTextColor,
    routeBadgeLabel: routeBadgeLabel,
    routeBadge: routeBadge,
    resolveConfiguredStopId: resolveConfiguredStopId,
    collectRows: collectRows,
    countdownLabel: countdownLabel,
    buildBoard: buildBoard,
    linePinKey: linePinKey,
    pinnedNextLabel: pinnedNextLabel,
    scheduleWindow: scheduleWindow,
    dedupeStops: dedupeStops,
    filterStations: filterStations,
    escapeRegExp: escapeRegExp,
    parseLatLon: parseLatLon,
    radiusDegrees: radiusDegrees,
    haversineMeters: haversineMeters,
    formatDistance: formatDistance,
    nearbyUrl: nearbyUrl,
    geocodeUrl: geocodeUrl,
    shortPlaceName: shortPlaceName,
    parseGeocoding: parseGeocoding,
    collectNearbyStops: collectNearbyStops
  }
}

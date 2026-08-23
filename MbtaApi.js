// Request-and-payload seam for MBTA API v3. A descriptor couples the exact
// sparse-field request with the only payload normalization valid for it.

function requireDomain(domain) {
  if (domain) return domain
  if (typeof require === "function") return require("./Mbta.js")
  throw new Error("MbtaApi requires the Mbta domain module")
}

function parseJson(raw, kind) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") throw new Error(kind + " returned an empty payload")
  var payload = JSON.parse(text)
  if (!payload || typeof payload !== "object") throw new Error(kind + " returned an invalid payload")
  return payload
}

function requireCollection(payload, kind) {
  if (!payload || !Array.isArray(payload.data))
    throw new Error(kind + " returned an invalid collection")
  return payload
}

function descriptor(kind, profile, url, context, cacheKey, cacheNamespace) {
  return {
    kind: kind,
    profile: profile,
    url: String(url || ""),
    context: context || {},
    cacheKey: String(cacheKey || ""),
    cacheNamespace: String(cacheNamespace || "")
  }
}

function create(domain) {
  var Mbta = requireDomain(domain)

  function request(kind, profile, url, context, cacheKey, cacheNamespace) {
    var value = descriptor(kind, profile, url, context, cacheKey, cacheNamespace)
    value.accept = function(raw) { return accept(value, raw) }
    return value
  }

  function predictions(stopIds, nowMs) {
    var ids = (stopIds || []).slice()
    return request("predictions", "arrival", Mbta.predictionsUrl(ids), {
      stopIds: ids, nowMs: Number(nowMs)
    }, "predictions:" + Mbta.serializeStopIds(ids))
  }

  function schedules(stopIds, window, nowMs) {
    var ids = (stopIds || []).slice()
    var serviceWindow = window || Mbta.scheduleWindow(new Date())
    return request("schedules", "arrival",
      Mbta.schedulesUrl(ids, serviceWindow.date, serviceWindow.min, serviceWindow.max), {
        stopIds: ids, window: serviceWindow, nowMs: Number(nowMs)
    }, "schedules:" + Mbta.serializeStopIds(ids) + ":" + serviceWindow.date, "schedules")
  }

  function stations() {
    return request("stations", "stations", Mbta.stationsUrl(), {}, "stations", "stations")
  }

  function geocode(query) {
    var value = String(query || "").slice(0, 200).replace(/^\s+|\s+$/g, "")
    return request("geocode", "geocode", Mbta.geocodeUrl(value), { query: value },
      "geocode:" + value, "geocode")
  }

  function exactTripStops(tripId, generation) {
    var id = String(tripId || "")
    return request("exact-trip-stops", "line-stops", Mbta.lineStopsUrl(id), {
      tripId: id, generation: Number(generation)
    }, "exact-trip-stops:" + id, "exact-trip-stops")
  }

  function vehicles(routeId, directionId, orderedStops, generation) {
    var id = String(routeId || "")
    var direction = Number(directionId)
    return request("vehicles", "line-vehicles", Mbta.vehiclesUrl(id, direction), {
      routeId: id,
      directionId: direction,
      orderedStops: (orderedStops || []).slice(),
      generation: Number(generation)
    }, "vehicles:" + id + "|" + String(direction))
  }

  function nearby(latitude, longitude, radiusKm) {
    var lat = Number(latitude)
    var lon = Number(longitude)
    return request("nearby", "nearby", Mbta.nearbyUrl(lat, lon, radiusKm), {
      latitude: lat, longitude: lon, radiusKm: Number(radiusKm)
    }, "nearby:" + lat + ":" + lon + ":" + Number(radiusKm), "nearby")
  }

  function accept(request, raw) {
    if (!request || !request.kind || !request.profile || !request.url)
      throw new Error("invalid MBTA request descriptor")
    var profiles = {
      predictions: "arrival", schedules: "arrival", stations: "stations",
      geocode: "geocode",
      "exact-trip-stops": "line-stops", vehicles: "line-vehicles", nearby: "nearby"
    }
    if (profiles[request.kind] !== request.profile)
      throw new Error("request profile does not match payload kind")
    var context = request.context || {}
    switch (request.kind) {
    case "geocode":
      var geocodePayload = parseJson(raw, request.kind)
      if (!Array.isArray(geocodePayload)) throw new Error("geocode returned an invalid collection")
      return Mbta.parseGeocoding(String(raw || ""))
    case "predictions":
    case "schedules":
      var payload = requireCollection(parseJson(raw, request.kind), request.kind)
      var realtime = request.kind === "predictions"
      return {
        rows: Mbta.collectRows(payload, isFinite(context.nowMs) ? context.nowMs : Date.now(), realtime),
        index: Mbta.indexIncluded(payload.included),
        realtime: realtime
      }
    case "stations":
      payload = requireCollection(parseJson(raw, request.kind), request.kind)
      return Mbta.dedupeStops(payload.data)
    case "exact-trip-stops":
      payload = parseJson(raw, request.kind)
      if (!payload.data || !payload.data.relationships
          || !payload.data.relationships.stops
          || !Array.isArray(payload.data.relationships.stops.data)
          || !Array.isArray(payload.included))
        throw new Error("exact-trip-stops returned invalid relationships")
      return Mbta.parseLineStops(payload)
    case "vehicles":
      payload = requireCollection(parseJson(raw, request.kind), request.kind)
      return Mbta.parseVehicles(payload, context.orderedStops || [])
    case "nearby":
      payload = requireCollection(parseJson(raw, request.kind), request.kind)
      return Mbta.collectNearbyStops(payload, context.latitude, context.longitude)
    default:
      throw new Error("unsupported MBTA payload kind: " + request.kind)
    }
  }

  return {
    predictions: predictions,
    schedules: schedules,
    stations: stations,
    geocode: geocode,
    exactTripStops: exactTripStops,
    vehicles: vehicles,
    nearby: nearby,
    accept: accept
  }
}

if (typeof module !== "undefined") module.exports = { create: create }

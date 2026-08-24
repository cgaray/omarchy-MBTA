import QtQuick
import "Mbta.js" as Mbta

// Nonvisual station-discovery seam: the once-per-session system station list
// plus the name-search and nearby-search flows. Owns no transport — every
// network action is an intent submitted through the shared coordinator.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  required property var requests
  required property var api

  // Station picker cache (full system station list, fetched once per session).
  property var stationsCache: null
  property bool stationsLoading: false
  property real stationsLastAttemptMs: 0

  // ---- Nearby-station state. Nearby searches always use coordinates or an
  // address supplied by the user.
  property var lastOrigin: null
  property var nearbyResults: []
  property bool nearbyLoading: false
  property bool locating: false
  property string nearbyError: ""
  property real pendingRadiusKm: 1
  property real lastGeocodeStartedMs: 0
  property var geocodeCandidates: []

  QtObject { id: stationsOwner }
  QtObject { id: geocodeOwner }
  QtObject { id: nearbyOwner }

  function ensureStations() {
    if (root.stationsCache !== null || root.stationsLoading) return
    if (root.stationsLastAttemptMs > 0 && Date.now() - root.stationsLastAttemptMs < 600000) return
    root.stationsLastAttemptMs = Date.now()
    root.stationsLoading = true
    root.requests.request(stationsOwner, root.api.stations(), root.requests.interactive, function(outcome) {
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
    root.geocodeCandidates = []
    var coords = Mbta.parseLatLon(addressText)
    if (coords) {
      root.fetchNearby(coords.latitude, coords.longitude, radiusKm, "coordinates")
      return true
    }
    var query = String(addressText || "").slice(0, 200).replace(/^\s+|\s+$/g, "")
    if (query === "") {
      root.nearbyError = "Enter your location"
      return false
    }
    if (root.locating) return false
    // Nominatim's usage policy asks for at most one request per second; the
    // locating flag only guards overlap, so throttle repeats here too.
    var nowMs = Date.now()
    if (root.lastGeocodeStartedMs > 0 && nowMs - root.lastGeocodeStartedMs < 1100) {
      root.nearbyError = "One moment — try that again in a second"
      return false
    }
    root.lastGeocodeStartedMs = nowMs
    var request = root.api.geocode(query)
    root.pendingRadiusKm = radiusKm
    root.locating = true
    return root.requests.request(geocodeOwner, request, root.requests.interactive, function(outcome) {
      root.locating = false
      if (outcome.status !== "ok" || !outcome.value.length) {
        root.nearbyError = "Address not found"
        return
      }
      // Several places often share a name ("Davis"): offer the candidates
      // instead of silently scanning around the first hit.
      if (outcome.value.length > 1) {
        root.geocodeCandidates = outcome.value
        return
      }
      var hit = outcome.value[0]
      root.fetchNearby(hit.latitude, hit.longitude, root.pendingRadiusKm, hit.name)
    }) > 0
  }

  function useGeocodeCandidate(at) {
    var candidates = root.geocodeCandidates || []
    if (at < 0 || at >= candidates.length) return false
    var hit = candidates[at]
    root.geocodeCandidates = []
    root.fetchNearby(hit.latitude, hit.longitude, root.pendingRadiusKm, hit.name)
    return true
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
    root.requests.request(nearbyOwner, request, root.requests.interactive, function(outcome) {
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

  Component.onDestruction: {
    root.requests.cancelOwner(stationsOwner)
    root.requests.cancelOwner(geocodeOwner)
    root.requests.cancelOwner(nearbyOwner)
  }
}

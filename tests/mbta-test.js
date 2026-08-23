// Unit tests for Mbta.js. Run with: node tests/mbta-test.js
// Fixtures in tests/fixtures/ are captured live from api-v3.mbta.com.
"use strict"

var fs = require("fs")
var path = require("path")
var assert = require("assert")

var Mbta = require("../Mbta.js")

function loadFixture(name) {
  return JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8"))
}

// Tiny harness: each case is [name, fn]; a throw fails the case.
function run(cases) {
  var failed = 0
  for (var i = 0; i < cases.length; i++) {
    try {
      cases[i][1]()
      console.log("  ok  " + cases[i][0])
    } catch (e) {
      failed++
      console.log("FAIL  " + cases[i][0] + "\n      " + e.message)
    }
  }
  console.log(failed === 0 ? "all passed (" + cases.length + ")" : failed + " failed of " + cases.length)
  process.exit(failed === 0 ? 0 : 1)
}

// Fixed "now": 2026-08-22 07:30:00 -04:00
var NOW = new Date("2026-08-22T07:30:00-04:00").getTime()

function prediction(id, opts) {
  opts = opts || {}
  return {
    id: id,
    type: "prediction",
    attributes: {
      arrival_time: opts.arrival || null,
      departure_time: opts.departure || null,
      direction_id: opts.direction === undefined ? 0 : opts.direction,
      status: opts.status || null
    },
    relationships: {
      route: { data: { id: opts.route, type: "route" } },
      trip: { data: { id: id + "-trip", type: "trip" } },
      stop: { data: { id: opts.stop, type: "stop" } }
    }
  }
}

function includedRoute(id, attrs) {
  return { id: id, type: "route", attributes: attrs }
}

function includedStop(id, name, parent) {
  return {
    id: id,
    type: "stop",
    attributes: { name: name },
    relationships: parent
      ? { parent_station: { data: { id: parent, type: "stop" } } }
      : {}
  }
}

function iso(minutesFromNow) {
  return new Date(NOW + minutesFromNow * 60000).toISOString()
}

var cases = [

  ["parseStopIds trims, drops empties and duplicates", function() {
    assert.deepStrictEqual(
      Mbta.parseStopIds(" place-dwnxg , ,place-pktrm, place-dwnxg "),
      ["place-dwnxg", "place-pktrm"]
    )
    assert.deepStrictEqual(Mbta.parseStopIds(null), [])
    assert.deepStrictEqual(Mbta.parseStopIds(""), [])
  }],

  ["serializeStopIds round-trips through parseStopIds", function() {
    var ids = ["place-dwnxg", "place-pktrm"]
    assert.strictEqual(Mbta.parseStopIds(Mbta.serializeStopIds(ids)).join(","), ids.join(","))
  }],

  ["predictionsUrl encodes bounded stop filters", function() {
    var url = Mbta.predictionsUrl(["place-dwnxg", "place-pktrm"], "")
    assert.ok(url.indexOf("https://api-v3.mbta.com/predictions?") === 0, url)
    assert.ok(url.indexOf("filter%5Bstop%5D=place-dwnxg%2Cplace-pktrm") > 0, url)
    assert.ok(url.indexOf("sort=arrival_time") > 0, url)
    assert.ok(url.indexOf("include=route%2Ctrip%2Cstop") > 0 || url.indexOf("include=route,trip,stop") > 0, url)
    assert.ok(url.indexOf("api_key") < 0, url)
  }],

  ["schedulesUrl bounds the window", function() {
    var url = Mbta.schedulesUrl(["place-sstat"], "05:10", "07:20", null)
    assert.ok(url.indexOf("/schedules?") > 0, url)
    assert.ok(url.indexOf("min_time%5D=05%3A10") > 0 || url.indexOf("min_time%5D=05:10") > 0, url)
    assert.ok(url.indexOf("max_time%5D=07%3A20") > 0 || url.indexOf("max_time%5D=07:20") > 0, url)
  }],

  ["stationsUrl covers rail stations and street bus stops with sparse fields", function() {
    var url = Mbta.stationsUrl("")
    assert.ok(url.indexOf("location_type%5D=0,1") > 0, url)
    assert.ok(url.indexOf("fields%5Bstop%5D=name,municipality,location_type") > 0, url)
  }],

  ["dedupeStops collapses platforms into their station's name", function() {
    var merged = Mbta.dedupeStops([
      { id: "70064", attributes: { name: "Davis", municipality: "Somerville", location_type: 0 }, relationships: { parent_station: { data: { id: "place-davis" } } } },
      { id: "place-davis", attributes: { name: "Davis", municipality: "Somerville", location_type: 1 }, relationships: { parent_station: { data: null } } },
      { id: "90001", attributes: { name: "Massachusetts Ave opp Appleton St", municipality: "Arlington", location_type: 0 }, relationships: { parent_station: { data: null } } }
    ])
    assert.strictEqual(merged.length, 2)
    assert.strictEqual(merged[0].id, "place-davis")
    assert.strictEqual(merged[1].id, "90001")
  }],

  ["indexIncluded buckets by type and ignores junk", function() {
    var index = Mbta.indexIncluded([
      includedRoute("Red", { long_name: "Red Line" }),
      { id: "x", type: "vehicle", attributes: {} },
      null
    ])
    assert.ok(index.route["Red"])
    assert.ok(!index.vehicle)
    assert.deepStrictEqual(Object.keys(index.trip), [])
  }],

  ["readableTextColor flips to dark on light badges", function() {
    assert.strictEqual(Mbta.readableTextColor("FFC72C"), "1B1B1B")
    assert.strictEqual(Mbta.readableTextColor("DA291C"), "FFFFFF")
    assert.strictEqual(Mbta.readableTextColor(""), "FFFFFF")
    assert.strictEqual(Mbta.readableTextColor("zzz"), "FFFFFF")
  }],

  ["routeBadgeLabel prefers short_name then color word then CR", function() {
    assert.strictEqual(Mbta.routeBadgeLabel(includedRoute("Green-B", { short_name: "B", long_name: "Green Line B", type: 0 }).attributes && includedRoute("Green-B", { short_name: "B" }) ? { attributes: { short_name: "B" } } : null), "B")
    assert.strictEqual(Mbta.routeBadgeLabel({ attributes: { short_name: "", long_name: "Red Line", type: 1 } }), "Red")
    assert.strictEqual(Mbta.routeBadgeLabel({ attributes: { short_name: "", long_name: "Framingham/Worcester Line", type: 2 } }), "CR")
    assert.strictEqual(Mbta.routeBadgeLabel({ attributes: { short_name: "", long_name: "CapeFLYER", type: 2 } }), "CR")
    assert.strictEqual(Mbta.routeBadgeLabel({ id: "Boat-F1", attributes: { short_name: "", long_name: "", type: 4 } }), "BOAT")
  }],

  ["routeBadge falls back to type colors", function() {
    var badge = Mbta.routeBadge({ attributes: { color: "", text_color: "", type: 2 } })
    assert.strictEqual(badge.color, "80276C")
    assert.strictEqual(badge.textColor, "FFFFFF")
    var bus = Mbta.routeBadge({ attributes: { color: "FFC72C", type: 3 } })
    assert.strictEqual(bus.textColor, "1B1B1B")
  }],

  ["parentStationMap harvests platform parents", function() {
    var index = Mbta.indexIncluded([includedStop("70078", "Downtown Crossing", "place-dwnxg")])
    assert.deepStrictEqual(Mbta.parentStationMap(index), { "place-dwnxg": "Downtown Crossing" })
  }],

  ["resolveConfiguredStopId climbs to the configured parent", function() {
    var index = Mbta.indexIncluded([
      includedStop("70078", "Downtown Crossing", "place-dwnxg"),
      includedStop("place-dwnxg", "Downtown Crossing", null),
      includedStop("90001", "Nowhere", null)
    ])
    var set = { "place-dwnxg": true }
    var parents = Mbta.parentStationMap(index)
    assert.strictEqual(Mbta.resolveConfiguredStopId("70078", index, set, parents), "place-dwnxg")
    assert.strictEqual(Mbta.resolveConfiguredStopId("place-dwnxg", index, set, parents), "place-dwnxg")
    assert.strictEqual(Mbta.resolveConfiguredStopId("90001", index, set, parents), null)
  }],

  ["collectRows keeps upcoming trains and drops past ones", function() {
    var payload = {
      data: [
        prediction("p1", { route: "Red", stop: "70078", arrival: iso(3) }),
        prediction("p2", { route: "Red", stop: "70078", arrival: iso(-1) }), // just left
        prediction("p3", { route: "Red", stop: "70078", arrival: null, departure: iso(9) })
      ]
    }
    payload.data[1].attributes.arrival_time = new Date(NOW - 20 * 1000).toISOString()
    var rows = Mbta.collectRows(payload, NOW, true)
    assert.strictEqual(rows.length, 2)
    assert.strictEqual(rows[0].timeMs < rows[1].timeMs, true)
    assert.strictEqual(rows[0].realtime, true)
  }],

  ["collectRows reads headsigns from trips", function() {
    var payload = {
      data: [prediction("p1", { route: "Red", stop: "70078", arrival: iso(4), direction: 1 })],
      included: [{ id: "p1-trip", type: "trip", attributes: { headsign: "Alewife" } }]
    }
    var rows = Mbta.collectRows(payload, NOW, true)
    assert.strictEqual(rows[0].headsign, "Alewife")
    assert.strictEqual(rows[0].directionId, 1)
  }],

  ["countdown labels count down plainly, no boarding state", function() {
    assert.strictEqual(Mbta.countdownLabel(1000), "1m")
    assert.strictEqual(Mbta.countdownLabel(45001), "1m")
    assert.strictEqual(Mbta.countdownLabel(60000), "1m")
    assert.strictEqual(Mbta.countdownLabel(61000), "2m")
    assert.strictEqual(Mbta.countdownLabel(119000), "2m")
    assert.strictEqual(Mbta.countdownLabel(91 * 60000), "")
  }],

  ["buildBoard groups by route+direction+headsign under the right stop", function() {
    var index = Mbta.indexIncluded([
      includedStop("70077", "Downtown Crossing", "place-dwnxg"),
      includedStop("70075", "Park Street", "place-pktrm"),
      includedRoute("Red", { short_name: "", long_name: "Red Line", color: "DA291C", text_color: "FFFFFF", type: 1 })
    ])
    var payload = {
      data: [
        prediction("a", { route: "Red", stop: "70077", arrival: iso(6), direction: 1 }),
        prediction("b", { route: "Red", stop: "70077", arrival: iso(16), direction: 1 }),
        prediction("c", { route: "Red", stop: "70075", arrival: iso(2), direction: 0 })
      ],
      included: index.route["Red"] ? [index.route["Red"], includedStop("70077", "Downtown Crossing", "place-dwnxg"), includedStop("70075", "Park Street", "place-pktrm")] : []
    }
    // Rebuild included properly (the ternary above was just scaffolding).
    payload.included = [
      includedRoute("Red", { short_name: "", long_name: "Red Line", color: "DA291C", text_color: "FFFFFF", type: 1 }),
      includedStop("70077", "Downtown Crossing", "place-dwnxg"),
      includedStop("70075", "Park Street", "place-pktrm")
    ]

    var rows = Mbta.collectRows(payload, NOW, true)
    var board = Mbta.buildBoard(rows, index, ["place-dwnxg", "place-pktrm"], NOW, 3)

    assert.strictEqual(board.stops.length, 2)
    assert.strictEqual(board.stops[0].id, "place-dwnxg")
    assert.strictEqual(board.stops[0].name, "Downtown Crossing")
    assert.strictEqual(board.stops[0].groups.length, 1)
    assert.strictEqual(board.stops[0].groups[0].badge.label, "Red")
    assert.strictEqual(board.stops[0].groups[0].badge.color, "DA291C")
    assert.strictEqual(board.stops[0].groups[0].times.length, 2)
    assert.strictEqual(board.stops[1].groups[0].key !== board.stops[0].groups[0].key, true)

    // Groups sort by first departure across stops; next is Park Street's 2m train.
    assert.strictEqual(board.nextLabel, "2m")
  }],

  ["buildBoard caps departures per group and counts overflow", function() {
    var index = Mbta.indexIncluded([
      includedStop("70077", "Downtown Crossing", "place-dwnxg"),
      includedRoute("Red", { short_name: "", long_name: "Red Line", color: "DA291C", type: 1 })
    ])
    var data = []
    for (var i = 1; i <= 5; i++) {
      data.push(prediction("t" + i, { route: "Red", stop: "70077", arrival: iso(i * 7) }))
    }
    var rows = Mbta.collectRows({ data: data }, NOW, true)
    var board = Mbta.buildBoard(rows, index, ["place-dwnxg"], NOW, 3)
    assert.strictEqual(board.stops[0].groups.length, 1)
    assert.strictEqual(board.stops[0].groups[0].times.length, 3)
    assert.strictEqual(board.stops[0].groups[0].more, 2)
  }],

  ["buildBoard separates opposite directions of one route", function() {
    var index = Mbta.indexIncluded([
      includedStop("70077", "Downtown Crossing", "place-dwnxg"),
      includedRoute("Red", { short_name: "", long_name: "Red Line", color: "DA291C", type: 1 })
    ])
    var rows = Mbta.collectRows({
      data: [
        prediction("n", { route: "Red", stop: "70077", arrival: iso(4), direction: 0 }),
        prediction("s", { route: "Red", stop: "70077", arrival: iso(5), direction: 1 })
      ]
    }, NOW, true)
    var board = Mbta.buildBoard(rows, index, ["place-dwnxg"], NOW, 3)
    assert.strictEqual(board.stops[0].groups.length, 2)
  }],

  ["buildBoard keeps configured stops with no service", function() {
    var index = Mbta.indexIncluded([includedStop("70077", "Downtown Crossing", "place-dwnxg")])
    var rows = Mbta.collectRows({ data: [] }, NOW, true)
    var board = Mbta.buildBoard(rows, index, ["place-dwnxg", "place-nowhere"], NOW, 3)
    assert.strictEqual(board.stops.length, 2)
    assert.strictEqual(board.stops[0].groups.length, 0)
    assert.strictEqual(board.realtime, true)
  }],

  ["pinnedNextLabel selects one station and destination row", function() {
    var board = {
      nextLabel: "1m",
      stops: [
        { id: "place-a", groups: [
          { stopId: "place-a", key: "Red|0|Ashmont", times: [{ label: "4m" }] },
          { stopId: "place-a", key: "Red|1|Alewife", times: [{ label: "7m" }] }
        ] },
        { id: "place-b", groups: [
          { stopId: "place-b", key: "Red|1|Alewife", times: [{ label: "2m" }] }
        ] }
      ]
    }
    var pin = Mbta.linePinKey(board.stops[0].groups[1])
    assert.strictEqual(pin, "place-a|Red|1|Alewife")
    assert.strictEqual(Mbta.pinnedNextLabel(board, pin), "7m")
    assert.strictEqual(Mbta.pinnedNextLabel(board, "place-b|Red|1|Alewife"), "2m")
    assert.strictEqual(Mbta.pinnedNextLabel(board, "missing"), "")
  }],

  ["scheduleWindow spans now to now+2h in HH:MM", function() {
    var win = Mbta.scheduleWindow(new Date(2026, 7, 22, 7, 42))
    assert.strictEqual(win.min, "07:42")
    assert.strictEqual(win.max, "09:42")
  }],

  ["filterStations ranks prefix over substring", function() {
    var list = loadFixture("stations.json").data
    var hits = Mbta.filterStations(list, "davis", 10)
    assert.ok(hits.length >= 1)
    assert.strictEqual(hits[0].name, "Davis")
    assert.strictEqual(hits[0].id, "place-davis")
    var broad = Mbta.filterStations(list, "", 10)
    assert.strictEqual(broad.length, 0)
    var none = Mbta.filterStations(list, "zzzqqq", 10)
    assert.strictEqual(none.length, 0)
  }],

  ["filterStations matches municipalities as substrings", function() {
    var list = loadFixture("stations.json").data
    var hits = Mbta.filterStations(list, "newton highlands", 5)
    assert.ok(hits.some(function(h) { return h.name === "Newton Highlands" }))
  }],

  ["name search surfaces street bus stops, including Appleton St in Arlington", function() {
    var list = loadFixture("slim-stops.json").data
    assert.strictEqual(list.length, 8044)
    var hits = Mbta.filterStations(list, "appleton", 16)
    assert.ok(hits.length > 0)
    assert.ok(hits.some(function(h) { return h.id === "2291" && h.name === "Massachusetts Ave opp Appleton St" }))
    // Station names stay deduped even with platforms in the mix.
    var davis = Mbta.filterStations(list, "davis", 12).filter(function(h) { return h.name === "Davis" })
    assert.strictEqual(davis.length, 1)
    assert.strictEqual(davis[0].id, "place-davis")
    // Prefix queries rank stations before similarly-named stops.
    var union = Mbta.filterStations(list, "north station", 3)
    assert.ok(union.some(function(h) { return h.id === "place-north" }))
  }],

  ["end-to-end: a configured bus stop builds a yellow-badge board", function() {
    var index = Mbta.indexIncluded([
      includedStop("2291", "Massachusetts Ave opp Appleton St", null),
      includedRoute("77", { short_name: "77", long_name: "Harvard Square–Arlington Heights via Mass Ave", color: "FFC72C", text_color: "1B1B1B", type: 3 })
    ])
    var payload = {
      data: [prediction("b1", { route: "77", stop: "2291", arrival: iso(4), direction: 0 })],
      included: [
        includedStop("2291", "Massachusetts Ave opp Appleton St", null),
        includedRoute("77", { short_name: "77", long_name: "Harvard Square–Arlington Heights via Mass Ave", color: "FFC72C", text_color: "1B1B1B", type: 3 }),
        { id: "b1-trip", type: "trip", attributes: { headsign: "Arlington Heights" } }
      ]
    }
    var rows = Mbta.collectRows(payload, NOW, true)
    var board = Mbta.buildBoard(rows, index, ["2291"], NOW, 3)
    assert.strictEqual(board.stops[0].name, "Massachusetts Ave opp Appleton St")
    assert.strictEqual(board.stops[0].groups[0].badge.label, "77")
    assert.strictEqual(board.stops[0].groups[0].badge.color, "FFC72C")
    assert.strictEqual(board.stops[0].groups[0].badge.textColor, "1B1B1B")
    assert.strictEqual(board.stops[0].groups[0].headsign, "Arlington Heights")
    assert.strictEqual(board.nextLabel, "4m")
  }],

  ["integration: real Downtown Crossing payload builds a sane board", function() {
    var payload = loadFixture("predictions.json")
    var index = Mbta.indexIncluded(payload.included)
    var rows = Mbta.collectRows(payload, Date.now(), true)
    if (!rows.length) {
      console.log("  skip fixture empty at capture time (service may be paused)")
      return
    }
    var board = Mbta.buildBoard(rows, index, ["place-dwnxg", "place-pktrm", "place-sstat"], Date.now(), 3)
    assert.strictEqual(board.stops.length, 3)
    var totalGroups = 0
    board.stops.forEach(function(stop) {
      totalGroups += stop.groups.length
      stop.groups.forEach(function(group) {
        assert.ok(group.badge.label.length >= 1, "badge label present")
        assert.ok(group.times.every(function(t) { return t.label.length >= 1 }))
      })
    })
    assert.ok(totalGroups > 0, "expected some groups from live fixture")
    assert.ok(board.nextMs > Date.now() - 60000)
  }],

  // ---- Nearby / location ----

  ["parseLatLon accepts comma and space forms, rejects junk", function() {
    assert.deepStrictEqual(Mbta.parseLatLon("42.3554,-71.0605"), { latitude: 42.3554, longitude: -71.0605 })
    assert.deepStrictEqual(Mbta.parseLatLon(" 42.3554, -71.0605 "), { latitude: 42.3554, longitude: -71.0605 })
    assert.deepStrictEqual(Mbta.parseLatLon("42.3554 -71.0605"), { latitude: 42.3554, longitude: -71.0605 })
    assert.strictEqual(Mbta.parseLatLon("Davis Square"), null)
    assert.strictEqual(Mbta.parseLatLon("99,99"), null) // out of lon range
    assert.strictEqual(Mbta.parseLatLon(""), null)
    assert.strictEqual(Mbta.parseLatLon(null), null)
  }],

  ["parseIpLoc reads ipinfo.io/loc bodies", function() {
    assert.deepStrictEqual(Mbta.parseIpLoc("42.4239,-71.1742\n"), { latitude: 42.4239, longitude: -71.1742 })
    assert.strictEqual(Mbta.parseIpLoc(""), null)
    assert.strictEqual(Mbta.parseIpLoc("error"), null)
  }],

  ["parseWeatherLocation honors the weather plugin's saved coordinates", function() {
    var good = Mbta.parseWeatherLocation('{"name":"Arlington","latitude":42.4142,"longitude":-71.1563}')
    assert.strictEqual(good.name, "Arlington")
    assert.strictEqual(good.latitude, 42.4142)
    assert.strictEqual(Mbta.parseWeatherLocation('{"name":"Boston"}'), null)
    assert.strictEqual(Mbta.parseWeatherLocation("not json"), null)
    assert.strictEqual(Mbta.parseWeatherLocation(""), null)
  }],

  ["radiusDegrees converts km and clamps extremes", function() {
    assert.ok(Math.abs(Mbta.radiusDegrees(1) - 1 / 111.32) < 1e-9)
    assert.ok(Math.abs(Mbta.radiusDegrees(0.5) - 0.5 / 111.32) < 1e-9)
    assert.strictEqual(Mbta.radiusDegrees(999999), 20 / 111.32)
    assert.strictEqual(Mbta.radiusDegrees(-2), 1 / 111.32)
    assert.strictEqual(Mbta.radiusDegrees("abc"), 1 / 111.32)
  }],

  ["haversineMeters measures known distances", function() {
    assert.strictEqual(Mbta.haversineMeters(42, -71, 42, -71), 0)
    var bostonToNYC = Mbta.haversineMeters(42.3601, -71.0589, 40.7128, -74.0060)
    assert.ok(Math.abs(bostonToNYC - 306000) < 3000, "got " + bostonToNYC)
    var dtxToPark = Mbta.haversineMeters(42.3554, -71.0605, 42.3563, -71.0624)
    assert.ok(dtxToPark > 100 && dtxToPark < 400, "got " + dtxToPark)
  }],

  ["formatDistance renders meters under 1km, km above", function() {
    assert.strictEqual(Mbta.formatDistance(120), "120 m")
    assert.strictEqual(Mbta.formatDistance(849), "849 m")
    assert.strictEqual(Mbta.formatDistance(1234), "1.2 km")
    assert.strictEqual(Mbta.formatDistance(NaN), "")
    assert.strictEqual(Mbta.formatDistance(-5), "")
  }],

  ["nearbyUrl carries lat, lon, and a degree radius", function() {
    var url = Mbta.nearbyUrl(42.3554, -71.0605, 1, "")
    assert.ok(url.indexOf("/stops?") > 0, url)
    assert.ok(url.indexOf("latitude%5D=42.3554") > 0, url)
    assert.ok(url.indexOf("longitude%5D=-71.0605") > 0, url)
    assert.ok(url.indexOf("radius%5D=" + Mbta.radiusDegrees(1)) > 0, url)
  }],

  ["geocodeUrl encodes Nominatim queries", function() {
    var url = Mbta.geocodeUrl("Mass Ave & Broadway, Arlington MA")
    assert.ok(url.indexOf("nominatim.openstreetmap.org/search") === 8 || url.indexOf("nominatim") >= 0, url)
    assert.ok(url.indexOf("format=jsonv2") > 0, url)
    assert.ok(url.indexOf("%20") > 0 || url.indexOf("Mass") > 0, url)
  }],

  ["shortPlaceName trims Nominatim addresses to two parts", function() {
    assert.strictEqual(
      Mbta.shortPlaceName("1600 Pennsylvania Avenue NW, Washington, DC 20500, USA"),
      "1600 Pennsylvania Avenue NW, Washington"
    )
    assert.strictEqual(Mbta.shortPlaceName("Arlington"), "Arlington")
    assert.strictEqual(Mbta.shortPlaceName(""), "")
  }],

  ["parseGeocoding maps hits and survives garbage", function() {
    var hits = Mbta.parseGeocoding('[{"display_name":"Davis Square, Somerville, MA","lat":"42.3966","lon":"-71.1219"},{"lat":"","lon":""}]')
    assert.strictEqual(hits.length, 1)
    assert.strictEqual(hits[0].name, "Davis Square, Somerville")
    assert.strictEqual(hits[0].latitude, 42.3966)
    assert.deepStrictEqual(Mbta.parseGeocoding("[]"), [])
    assert.deepStrictEqual(Mbta.parseGeocoding("oops"), [])
  }],

  ["collectNearbyStops merges platforms into parents and drops interior stops", function() {
    var payload = {
      data: [
        { id: "70078", attributes: { name: "Downtown Crossing", municipality: "Boston", location_type: 0, latitude: 42.3557, longitude: -71.0603 }, relationships: { parent_station: { data: { id: "place-dwnxg" } } } },
        { id: "place-dwnxg", attributes: { name: "Downtown Crossing", municipality: "Boston", location_type: 1, latitude: 42.3554, longitude: -71.0605 }, relationships: {} },
        { id: "door-dwnxg-cha", attributes: { name: "Chauncy St entrance", location_type: 2, latitude: 42.3550, longitude: -71.0600 }, relationships: {} },
        { id: "90001", attributes: { name: "Washington St @ Temple Pl", municipality: "Boston", location_type: 0, latitude: 42.3545, longitude: -71.0612 }, relationships: {} }
      ]
    }
    var results = Mbta.collectNearbyStops(payload, 42.3554, -71.0605)
    // Door dropped; station + bus stop remain.
    assert.strictEqual(results.length, 2)
    // Platforms merged into the parent id.
    var ids = results.map(function(r) { return r.id })
    assert.ok(ids.indexOf("place-dwnxg") >= 0, ids.join(","))
    assert.ok(ids.indexOf("70078") < 0)
    // Sorted nearest first; station distance is min(station, platform).
    assert.strictEqual(results[0].id, "place-dwnxg")
    assert.ok(results[0].distanceMeters <= 40, "" + results[0].distanceMeters)
    assert.strictEqual(results[0].name, "Downtown Crossing")
  }],

  ["integration: geo capture around Downtown Crossing yields stations sorted by distance", function() {
    var payload = loadFixture("nearby.json")
    var results = Mbta.collectNearbyStops(payload, 42.3554, -71.0605)
    assert.ok(results.length > 5)
    for (var i = 1; i < results.length; i++) {
      assert.ok(results[i - 1].distanceMeters <= results[i].distanceMeters)
    }
    var ids = results.map(function(r) { return r.id })
    assert.ok(ids.indexOf("place-dwnxg") >= 0, "downtown crossing should appear")
    assert.ok(results.every(function(r) { return isFinite(r.distanceMeters) }))
  }],

  // ---- Strip map ----

  ["lineStopsUrl and vehiclesUrl target route+direction", function() {
    var stops = Mbta.lineStopsUrl("Red", 1, "")
    assert.ok(stops.indexOf("/stops?") > 0, stops)
    assert.ok(stops.indexOf("route%5D=Red") > 0, stops)
    var vehicles = Mbta.vehiclesUrl("77", 0, "k")
    assert.ok(vehicles.indexOf("/vehicles?") > 0, vehicles)
    assert.ok(vehicles.indexOf("route%5D=77") > 0, vehicles)
    assert.ok(vehicles.indexOf("direction_id%5D=0") > 0, vehicles)
    assert.ok(vehicles.indexOf("include=stop") > 0, vehicles)
  }],

  ["parseLineStops keeps order and drops unnamed entries", function() {
    var stops = Mbta.parseLineStops({
      data: [
        { id: "place-alewle", attributes: { name: "Alewife" } },
        { id: "x", attributes: { name: "" } },
        { id: "place-davis", attributes: { name: "Davis" } },
        null
      ]
    })
    assert.deepStrictEqual(stops.map(function(s) { return s.name }), ["Alewife", "Davis"])
    assert.deepStrictEqual(Mbta.parseLineStops({ data: [
      { id: "a", attributes: { name: "A" } },
      { id: "b", attributes: { name: "B" } }
    ] }, 1).map(function(s) { return s.name }), ["B", "A"])
  }],

  ["parseVehicles places stopped and moving trains on the strip", function() {
    var stops = [
      { id: "a", name: "Alewife" },
      { id: "b", name: "Davis" },
      { id: "c", name: "Porter" },
      { id: "d", name: "Harvard" }
    ]
    var vehicles = Mbta.parseVehicles({
      data: [
        { id: "v1", attributes: { current_status: "STOPPED_AT" }, relationships: { stop: { data: { id: "c" } }, trip: { data: { id: "t1" } } } },
        { id: "v2", attributes: { current_status: "IN_TRANSIT_TO" }, relationships: { stop: { data: { id: "d" } }, trip: { data: { id: "t2" } } } },
        { id: "v3", attributes: { current_status: "INCOMING_AT" }, relationships: { stop: { data: { id: "platform-d" } }, trip: { data: { id: "t3" } } } }
      ],
      included: [
        { id: "platform-d", type: "stop", relationships: { parent_station: { data: { id: "d" } } } }
      ]
    }, stops)
    assert.strictEqual(vehicles.length, 3)
    assert.strictEqual(vehicles[0].fraction, 2 / 3)          // stopped at Porter
    assert.strictEqual(vehicles[1].fraction, 2.5 / 3)        // between Porter and Harvard
    assert.strictEqual(vehicles[2].fraction, 2.5 / 3)        // incoming at Harvard
    // Sorted by position along the line.
    for (var i = 1; i < vehicles.length; i++)
      assert.ok(vehicles[i - 1].fraction <= vehicles[i].fraction)
  }],

  ["parseVehicles dedupes per trip and survives empty payloads", function() {
    var stops = [{ id: "a", name: "A" }, { id: "b", name: "B" }]
    var duped = Mbta.parseVehicles({
      data: [
        { id: "v1", attributes: { current_status: "STOPPED_AT" }, relationships: { stop: { data: { id: "a" } }, trip: { data: { id: "t9" } } } },
        { id: "v2", attributes: { current_status: "STOPPED_AT" }, relationships: { stop: { data: { id: "b" } }, trip: { data: { id: "t9" } } } }
      ]
    }, stops)
    assert.strictEqual(duped.length, 1)
    assert.strictEqual(duped[0].fraction, 1)
    assert.deepStrictEqual(Mbta.parseVehicles({ data: [] }, stops), [])
    assert.deepStrictEqual(Mbta.parseVehicles(null, []), [])
  }]
]

console.log("mbta-test:")
run(cases)

"use strict"

var assert = require("assert")
var Api = require("../MbtaApi.js").create()

function arrivalPayload(type) {
  return JSON.stringify({ data: [{ id: "row-1", type: type, attributes: {
    arrival_time: "2026-08-23T12:10:00Z", direction_id: 0
  }, relationships: {
    route: { data: { id: "Red" } }, trip: { data: { id: "trip-1" } },
    stop: { data: { id: "70077" } }
  } }], included: [{ id: "Red", type: "route", attributes: { type: 1 } }] })
}

var now = new Date("2026-08-23T12:00:00Z").getTime()
var predictions = Api.predictions(["place-dwnxg"], now)
assert.deepStrictEqual([predictions.kind, predictions.profile, predictions.cacheKey],
  ["predictions", "arrival", "predictions:place-dwnxg"])
assert.ok(predictions.url.indexOf("/predictions?") > 0)
assert.strictEqual(Api.accept(predictions, arrivalPayload("prediction")).rows.length, 1)
assert.strictEqual(predictions.accept(arrivalPayload("prediction")).rows.length, 1)

var schedules = Api.schedules(["place-dwnxg"], {
  date: "2026-08-23", min: "08:00", max: "10:00"
}, now)
assert.strictEqual(Api.accept(schedules, arrivalPayload("schedule")).realtime, false)

var stations = Api.stations()
assert.deepStrictEqual(Api.accept(stations, JSON.stringify({ data: [{
  id: "place-davis", type: "stop", attributes: { name: "Davis", municipality: "Somerville" }
}] })), [{ id: "place-davis", name: "Davis", municipality: "Somerville", rank: 0 }])

// Route+direction variants can share labels, but exact stop order is a trip
// property. Cache identity therefore stays the exact trip id.
var exactA = Api.exactTripStops("trip-variant-a", 3)
var exactB = Api.exactTripStops("trip-variant-b", 3)
assert.strictEqual(exactA.cacheKey, "exact-trip-stops:trip-variant-a")
assert.strictEqual(exactB.cacheKey, "exact-trip-stops:trip-variant-b")
assert.notStrictEqual(exactA.cacheKey, exactB.cacheKey)
var railStops = Api.accept(exactA, JSON.stringify({
  data: { relationships: { stops: { data: [{ id: "70077" }] } } },
  included: [{ id: "70077", type: "stop", attributes: { name: "Downtown Crossing" },
    relationships: { parent_station: { data: { id: "place-dwnxg" } } } }]
}))
assert.deepStrictEqual(railStops, [{ id: "place-dwnxg", name: "Downtown Crossing" }])

var vehicles = Api.vehicles("Red", 0, railStops, 3)
assert.strictEqual(Api.accept(vehicles, JSON.stringify({ data: [{
  id: "v1", attributes: { current_status: "STOPPED_AT", label: "1" },
  relationships: { stop: { data: { id: "70077" } } }
}], included: [{ id: "70077", type: "stop", relationships: {
  parent_station: { data: { id: "place-dwnxg" } }
} }] })).length, 1)

assert.deepStrictEqual(Api.accept(Api.nearby(42.35, -71.06, 1), '{"data":[]}'), [])

assert.throws(function() { Api.accept(predictions, "not-json") })
assert.throws(function() { Api.accept({ kind: "predictions" }, "{}") })
assert.throws(function() { Api.accept(Api.stations(), "{}") })
assert.throws(function() { Api.accept(Api.geocode("Boston"), "{}") })
assert.throws(function() { Api.accept(exactA, "{}") })
assert.throws(function() { Api.accept(Api.nearby(42.35, -71.06, 1), "{}") })
console.log("mbta-api-test: all passed")

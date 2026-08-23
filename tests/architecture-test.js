"use strict"

var assert = require("assert")
var Activity = require("../PanelActivity.js")
var Polling = require("../PollingPolicy.js")
var Cache = require("../SessionCache.js")
var Coordinator = require("../RequestCoordinator.js")

function demand(overrides) {
  return Object.assign({
    jobId: "line-stops", revision: "trip-a", mode: "once",
    enabled: true, ready: true
  }, overrides || {})
}

// One-shot work remains satisfied after completion. This catches the route-stop
// completion loop that previously exhausted the MBTA quota.
var polling = Polling.create()
var first = Polling.reconcile(polling, 0, [demand()])
assert.strictEqual(first.effects.length, 1)
var token = first.effects[0].token
polling = Polling.complete(first.state, 100, { token: token, disposition: "success" }).state
var again = Polling.reconcile(polling, 60100, [demand()])
assert.deepStrictEqual(again.effects, [])
assert.strictEqual(again.nextWakeMs, null)

// Hiding an active line cancels its in-flight poll and schedules no hidden work.
var active = Activity.derive({ loaded: true, opened: true, managing: false,
  lineSelected: true, sideBySide: true })
assert.strictEqual(active.mode, "split-line")
polling = Polling.create()
first = Polling.reconcile(polling, 0, [demand({ jobId: "line-vehicles",
  mode: "interval", enabled: active.mode === "line" || active.mode === "split-line", everyMs: 60000 })])
var hidden = Activity.derive({ loaded: true, opened: false, managing: false,
  lineSelected: true, sideBySide: true })
var stopped = Polling.reconcile(first.state, 1000, [demand({ jobId: "line-vehicles",
  mode: "interval", enabled: hidden.mode === "line" || hidden.mode === "split-line", everyMs: 60000 })])
assert.deepStrictEqual(stopped.effects.map(function(effect) { return effect.type }), ["cancel"])
assert.strictEqual(stopped.nextWakeMs, null)
assert.strictEqual(Activity.derive({ loaded: true, opened: true, managing: true,
  lineSelected: true, sideBySide: true }).mode, "manage")
assert.strictEqual(Activity.derive({ loaded: true, opened: true, managing: false,
  lineSelected: false, sideBySide: false }).mode, "arrivals")
assert.strictEqual(Activity.derive({ loaded: true, opened: true, managing: false,
  lineSelected: false, sideBySide: true }).mode, "arrivals")

// Interval cadence starts from completion and never catches up with a burst.
polling = Polling.create()
first = Polling.reconcile(polling, 0, [demand({ jobId: "arrivals", mode: "interval", everyMs: 60000 })])
var noOverlap = Polling.reconcile(first.state, 180000,
  [demand({ jobId: "arrivals", mode: "interval", everyMs: 60000 })])
assert.deepStrictEqual(noOverlap.effects, [])
polling = Polling.complete(noOverlap.state, 180000,
  { token: first.effects[0].token, disposition: "success" }).state
assert.strictEqual(Polling.reconcile(polling, 239999,
  [demand({ jobId: "arrivals", mode: "interval", everyMs: 60000 })]).effects.length, 0)
assert.strictEqual(Polling.reconcile(polling, 240000,
  [demand({ jobId: "arrivals", mode: "interval", everyMs: 60000 })]).effects.length, 1)

// Policy calls return new state and force coalesces through the same job seam.
var immutableInput = Polling.create()
var immutableSnapshot = JSON.stringify(immutableInput)
var immutableResult = Polling.reconcile(immutableInput, 0,
  [demand({ jobId: "forced", mode: "interval", everyMs: 60000 })])
assert.strictEqual(JSON.stringify(immutableInput), immutableSnapshot)
var forcedToken = immutableResult.effects[0].token
var completedForce = Polling.complete(immutableResult.state, 100,
  { token: forcedToken, disposition: "success" })
var forced = Polling.force(completedForce.state, 200, "forced")
assert.strictEqual(Polling.reconcile(forced.state, 200,
  [demand({ jobId: "forced", mode: "interval", everyMs: 60000 })]).effects.length, 1)

var intervalState = Polling.create()
var intervalStart = Polling.reconcile(intervalState, 0,
  [demand({ jobId: "changing", mode: "interval", everyMs: 300000 })])
intervalState = Polling.complete(intervalStart.state, 1000,
  { token: intervalStart.effects[0].token, disposition: "success" }).state
var shortened = Polling.reconcile(intervalState, 61000,
  [demand({ jobId: "changing", mode: "interval", everyMs: 60000 })])
assert.strictEqual(shortened.effects.length, 1)

// Shared cache keeps namespaces isolated, honors exact TTL boundaries, and LRU-evicts.
var cache = Cache.create({ nearby: { maxEntries: 2, ttlMs: 1000 }, stations: { maxEntries: 1, ttlMs: null } })
cache.put("nearby", "a", [], 0)
assert.deepStrictEqual(cache.get("nearby", "a", 999), { hit: true, value: [] })
assert.strictEqual(cache.get("nearby", "a", 1000).hit, false)
cache.put("nearby", "a", 1, 2000)
cache.put("nearby", "b", 2, 2000)
cache.get("nearby", "a", 2001)
cache.put("nearby", "c", 3, 2002)
assert.strictEqual(cache.get("nearby", "b", 2002).hit, false)
assert.strictEqual(cache.get("nearby", "a", 2002).value, 1)
cache.put("stations", "a", null, 0)
assert.deepStrictEqual(cache.get("stations", "a", 999999), { hit: true, value: null })

// The coordinator deduplicates transport, prioritizes interactive work, caches raw
// responses, normalizes outcomes, and cancels by owner without leaking exit codes.
var deferred = []
var starts = []
var pending = []
var canceled = 0
var clock = 1000
var coordinator = Coordinator.create({
  now: function() { return clock },
  defer: function(callback) { deferred.push(callback) },
  start: function(descriptor, done) { starts.push(descriptor.kind); pending.push(done); return true },
  cancel: function() { canceled++; pending.shift() }
})
function descriptor(kind, key, cacheNamespace) {
  return { kind: kind, profile: kind, url: "https://example/" + key,
    cacheKey: kind + ":" + key, cacheNamespace: cacheNamespace || "",
    accept: function(raw) { return kind + "=" + raw } }
}
var ownerA = {}
var ownerB = {}
var outcomes = []
coordinator.request(ownerA, descriptor("active", "one"), 0, function(value) { outcomes.push(value) })
coordinator.request(ownerA, descriptor("background", "two"), 0, function(value) { outcomes.push(value) })
coordinator.request(ownerB, descriptor("interactive", "three"), 100, function(value) { outcomes.push(value) })
assert.deepStrictEqual(starts, ["active"])
pending.shift()({ ok: true, raw: "1" })
assert.deepStrictEqual(starts, ["active", "interactive"])
pending.shift()({ ok: true, raw: "3" })
assert.deepStrictEqual(starts, ["active", "interactive", "background"])
pending.shift()({ ok: true, raw: "2" })
while (deferred.length) deferred.shift()()
assert.deepStrictEqual(outcomes.map(function(value) { return value.status }), ["ok", "ok", "ok"])

starts = []
pending = []
outcomes = []
var cachedDescriptor = descriptor("stations", "all", "stations")
coordinator.request(ownerA, cachedDescriptor, 100, function(value) { outcomes.push(value) })
coordinator.request(ownerB, cachedDescriptor, 100, function(value) { outcomes.push(value) })
assert.strictEqual(starts.length, 1)
pending.shift()({ ok: true, raw: "payload" })
while (deferred.length) deferred.shift()()
assert.strictEqual(outcomes.length, 2)
assert.ok(outcomes.every(function(value) { return value.value === "stations=payload" }))
coordinator.request(ownerA, cachedDescriptor, 100, function(value) { outcomes.push(value) })
assert.strictEqual(starts.length, 1)
while (deferred.length) deferred.shift()()
assert.strictEqual(outcomes[2].source, "cache")

coordinator.request(ownerA, descriptor("slow", "one"), 0, function() { throw new Error("canceled callback") })
coordinator.cancelOwner(ownerA)
assert.strictEqual(canceled, 1)

// Cancellation also suppresses callbacks already deferred after completion.
var deferredOwner = {}
var deferredCalled = false
coordinator.request(deferredOwner, descriptor("deferred", "one"), 100,
  function() { deferredCalled = true })
pending.shift()({ ok: true, raw: "done" })
coordinator.cancelOwner(deferredOwner)
while (deferred.length) deferred.shift()()
assert.strictEqual(deferredCalled, false)

var failure = []
coordinator.request(ownerB, descriptor("failure", "one"), 100, function(value) { failure.push(value) })
pending.shift()({ ok: false, error: "rate-limited" })
while (deferred.length) deferred.shift()()
assert.deepStrictEqual(failure[0], { status: "error", error: { kind: "rate-limited", retryable: true },
  cacheKey: "failure:one" })
assert.strictEqual(Object.prototype.hasOwnProperty.call(failure[0], "exitCode"), false)

// Invalid payloads fail but never poison a session cache entry.
starts = []
pending = []
var malformed = { kind: "stations", profile: "stations", url: "https://example/bad",
  cacheKey: "stations:bad", cacheNamespace: "stations",
  accept: function(raw) { if (raw === "bad") throw new Error("bad"); return raw } }
var malformedOutcomes = []
coordinator.request(ownerB, malformed, 100, function(value) { malformedOutcomes.push(value) })
pending.shift()({ ok: true, raw: "bad" })
while (deferred.length) deferred.shift()()
assert.strictEqual(malformedOutcomes[0].error.kind, "invalid-payload")
coordinator.request(ownerB, malformed, 100, function(value) { malformedOutcomes.push(value) })
assert.strictEqual(starts.length, 2)

console.log("architecture-test: all passed")

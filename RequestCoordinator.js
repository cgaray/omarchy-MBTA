"use strict"

var SessionCache = typeof require === "function" ? require("./SessionCache.js") : null

var CACHE_POLICIES = {
  schedules: { maxEntries: 4, ttlMs: 300000 },
  stations: { maxEntries: 1, ttlMs: null },
  "exact-trip-stops": { maxEntries: 12, ttlMs: null },
  geocode: { maxEntries: 32, ttlMs: null },
  nearby: { maxEntries: 24, ttlMs: 600000 }
}

function create(options) {
  var config = options || {}
  var now = config.now || function() { return Date.now() }
  var defer = config.defer || function(callback) { callback() }
  var start = config.start
  var cancelTransport = config.cancel || function() {}
  var cacheFactory = SessionCache || config.sessionCache
  var cache = cacheFactory.create(CACHE_POLICIES)
  var entries = Object.create(null)
  var queue = []
  var active = null
  var sequence = 0
  var subscriptionId = 0
  var subscriptions = []

  function errorOutcome(kind, cacheKey) {
    return { status: "error", error: { kind: kind,
      retryable: kind === "rate-limited" || kind === "unavailable" || kind === "empty-response" },
      cacheKey: cacheKey }
  }

  function validDescriptor(descriptor) {
    return descriptor && descriptor.kind && descriptor.profile && descriptor.url
      && descriptor.cacheKey && typeof descriptor.accept === "function"
  }

  function deliver(subscriber, outcome) {
    if (subscriber.canceled) return
    defer(function() {
      try {
        if (!subscriber.canceled) subscriber.callback(outcome)
      } finally {
        subscriptions = subscriptions.filter(function(value) { return value !== subscriber })
      }
    })
  }

  function acceptedOutcome(descriptor, raw, source) {
    try {
      return { status: "ok", value: descriptor.accept(raw), cacheKey: descriptor.cacheKey, source: source }
    } catch (error) {
      return errorOutcome("invalid-payload", descriptor.cacheKey)
    }
  }

  function pump() {
    if (active || !queue.length) return
    queue.sort(function(a, b) { return b.priority - a.priority || a.sequence - b.sequence })
    active = queue.shift()
    active.phase = "running"
    if (!start || start(active.descriptor, finish) !== true) {
      var failed = active
      active = null
      delete entries[failed.key]
      for (var i = 0; i < failed.subscribers.length; i++)
        deliver(failed.subscribers[i], errorOutcome("unavailable", failed.descriptor.cacheKey))
      defer(pump)
    }
  }

  function finish(result) {
    if (!active) return
    var entry = active
    active = null
    delete entries[entry.key]
    var response = result || {}
    var validForCache = false
    if (response.ok && entry.descriptor.cacheNamespace) {
      try {
        entry.descriptor.accept(response.raw)
        validForCache = true
      } catch (error) {}
    }
    if (validForCache)
      cache.put(entry.descriptor.cacheNamespace, entry.descriptor.cacheKey, response.raw, now())
    for (var i = 0; i < entry.subscribers.length; i++) {
      var subscriber = entry.subscribers[i]
      var outcome = response.ok
        ? acceptedOutcome(subscriber.descriptor, response.raw, "network")
        : errorOutcome(String(response.error || "unavailable"), subscriber.descriptor.cacheKey)
      deliver(subscriber, outcome)
    }
    pump()
  }

  function request(owner, descriptor, priority, callback) {
    if (!owner || !validDescriptor(descriptor) || typeof callback !== "function") return 0
    var subscriber = { id: ++subscriptionId, owner: owner, descriptor: descriptor,
      callback: callback, canceled: false }
    subscriptions.push(subscriber)
    if (descriptor.cacheNamespace) {
      var cached = cache.get(descriptor.cacheNamespace, descriptor.cacheKey, now())
      if (cached.hit) {
        deliver(subscriber, acceptedOutcome(descriptor, cached.value, "cache"))
        return subscriber.id
      }
    }
    var key = String(descriptor.cacheKey)
    var existing = entries[key]
    if (existing) {
      if (existing.descriptor.kind !== descriptor.kind || existing.descriptor.profile !== descriptor.profile
          || existing.descriptor.url !== descriptor.url) {
        deliver(subscriber, errorOutcome("invalid-request", descriptor.cacheKey))
        return subscriber.id
      }
      existing.subscribers.push(subscriber)
      existing.priority = Math.max(existing.priority, Number(priority) || 0)
      return subscriber.id
    }
    var entry = { key: key, descriptor: descriptor, subscribers: [subscriber],
      priority: Number(priority) || 0, sequence: ++sequence, phase: "queued" }
    entries[key] = entry
    queue.push(entry)
    pump()
    return subscriber.id
  }

  function cancelOwner(owner) {
    var canceledActive = false
    for (var s = 0; s < subscriptions.length; s++)
      if (subscriptions[s].owner === owner) subscriptions[s].canceled = true
    subscriptions = subscriptions.filter(function(value) { return value.owner !== owner })
    for (var key in entries) {
      var entry = entries[key]
      for (var i = 0; i < entry.subscribers.length; i++) {
        if (entry.subscribers[i].owner === owner) entry.subscribers[i].canceled = true
      }
      entry.subscribers = entry.subscribers.filter(function(value) { return !value.canceled })
      if (entry.subscribers.length) continue
      if (entry === active) {
        canceledActive = true
        active = null
        cancelTransport()
      } else {
        queue = queue.filter(function(value) { return value !== entry })
      }
      delete entries[key]
    }
    if (canceledActive) defer(pump)
  }

  return { request: request, cancelOwner: cancelOwner }
}

if (typeof module !== "undefined") module.exports = { create: create }

"use strict"

function create(configuration) {
  var policies = configuration || {}
  var namespaces = Object.create(null)
  var serial = 0

  function policy(namespace) {
    var value = policies[namespace]
    if (!value) return null
    return {
      maxEntries: Math.max(1, Math.floor(Number(value.maxEntries) || 1)),
      ttlMs: value.ttlMs === null ? null : Math.max(0, Number(value.ttlMs) || 0)
    }
  }

  function bucket(namespace) {
    if (!namespaces[namespace]) namespaces[namespace] = Object.create(null)
    return namespaces[namespace]
  }

  function expired(entry, currentPolicy, nowMs) {
    return currentPolicy.ttlMs !== null
      && Number(nowMs) >= entry.storedAtMs + currentPolicy.ttlMs
  }

  function removeExpired(values, currentPolicy, nowMs) {
    for (var key in values)
      if (expired(values[key], currentPolicy, nowMs)) delete values[key]
  }

  function get(namespace, key, nowMs) {
    var currentPolicy = policy(namespace)
    if (!currentPolicy) return { hit: false }
    var values = bucket(namespace)
    var cacheKey = String(key || "")
    var entry = values[cacheKey]
    if (!entry) return { hit: false }
    if (expired(entry, currentPolicy, Number(nowMs))) {
      delete values[cacheKey]
      return { hit: false }
    }
    entry.used = ++serial
    return { hit: true, value: entry.value }
  }

  function put(namespace, key, value, nowMs) {
    var currentPolicy = policy(namespace)
    if (!currentPolicy) return false
    var values = bucket(namespace)
    removeExpired(values, currentPolicy, Number(nowMs))
    var cacheKey = String(key || "")
    values[cacheKey] = { value: value, storedAtMs: Number(nowMs), used: ++serial }
    var keys = Object.keys(values)
    while (keys.length > currentPolicy.maxEntries) {
      var oldest = keys[0]
      for (var i = 1; i < keys.length; i++)
        if (values[keys[i]].used < values[oldest].used) oldest = keys[i]
      delete values[oldest]
      keys = Object.keys(values)
    }
    return true
  }

  function clear(namespace) {
    if (namespace === undefined) namespaces = Object.create(null)
    else delete namespaces[String(namespace)]
  }

  return { get: get, put: put, clear: clear }
}

if (typeof module !== "undefined") module.exports = { create: create }

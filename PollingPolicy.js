"use strict"

function create() {
  return { jobs: Object.create(null), serial: 0 }
}

function ensureState(state) {
  return state && state.jobs ? state : create()
}

function copyState(state) {
  var source = ensureState(state)
  var jobs = Object.create(null)
  for (var jobId in source.jobs) {
    jobs[jobId] = {}
    for (var key in source.jobs[jobId]) jobs[jobId][key] = source.jobs[jobId][key]
  }
  return { jobs: jobs, serial: Number(source.serial) || 0 }
}

function demandMap(demands) {
  var result = Object.create(null)
  var values = Array.isArray(demands) ? demands : []
  for (var i = 0; i < values.length; i++) {
    var demand = values[i]
    if (demand && demand.jobId) result[String(demand.jobId)] = demand
  }
  return result
}

function reconcile(state, nowMs, demands) {
  var current = copyState(state)
  var now = Number(nowMs)
  var requested = demandMap(demands)
  var effects = []
  var nextWakeMs = null
  var jobId

  for (jobId in current.jobs) {
    if (requested[jobId]) continue
    if (current.jobs[jobId].token)
      effects.push({ type: "cancel", jobId: jobId, token: current.jobs[jobId].token })
    delete current.jobs[jobId]
  }

  for (jobId in requested) {
    var demand = requested[jobId]
    var revision = String(demand.revision || "")
    var job = current.jobs[jobId]
    if (!job || job.revision !== revision || job.mode !== demand.mode) {
      if (job && job.token) effects.push({ type: "cancel", jobId: jobId, token: job.token })
      job = { revision: revision, mode: demand.mode, token: "", satisfied: false,
        nextDueMs: null, retryAtMs: null, forcePending: false,
        everyMs: Math.max(1, Number(demand.everyMs) || 1), lastCompletedAtMs: null }
      current.jobs[jobId] = job
    }
    var nextEveryMs = Math.max(1, Number(demand.everyMs) || job.everyMs || 1)
    if (job.mode === "interval" && job.lastCompletedAtMs !== null
        && nextEveryMs !== job.everyMs)
      job.nextDueMs = job.lastCompletedAtMs + nextEveryMs
    job.everyMs = nextEveryMs

    if (demand.enabled !== true || demand.ready !== true) {
      if (job.token) {
        effects.push({ type: "cancel", jobId: jobId, token: job.token })
        job.token = ""
      }
      job.nextDueMs = null
      continue
    }

    var due = job.mode === "once" ? !job.satisfied : job.nextDueMs === null || now >= job.nextDueMs
    if (job.retryAtMs !== null) due = now >= job.retryAtMs
    if (job.forcePending && !job.token) due = true
    if (!job.token && due) {
      job.token = jobId + ":" + (++current.serial)
      job.forcePending = false
      job.retryAtMs = null
      effects.push({ type: "start", jobId: jobId, revision: revision, token: job.token })
    } else if (!job.token) {
      var wake = job.retryAtMs !== null ? job.retryAtMs : job.nextDueMs
      if (wake !== null && (nextWakeMs === null || wake < nextWakeMs)) nextWakeMs = wake
    }
  }
  return { state: current, effects: effects, nextWakeMs: nextWakeMs }
}

function complete(state, nowMs, result) {
  var current = copyState(state)
  var outcome = result || {}
  var found = null
  for (var jobId in current.jobs) {
    if (current.jobs[jobId].token === outcome.token) {
      found = current.jobs[jobId]
      break
    }
  }
  if (!found) return { state: current, effects: [], nextWakeMs: null }
  found.token = ""
  if (outcome.disposition === "retry") {
    found.retryAtMs = Number(outcome.retryAtMs)
  } else if (found.mode === "once") {
    found.satisfied = true
  } else {
    found.lastCompletedAtMs = Number(nowMs)
    found.nextDueMs = Number(nowMs) + found.everyMs
  }
  return { state: current, effects: [], nextWakeMs: found.retryAtMs !== null
    ? found.retryAtMs : found.nextDueMs }
}

function force(state, nowMs, jobId) {
  var current = copyState(state)
  var job = current.jobs[String(jobId)]
  if (job) {
    if (job.token) job.forcePending = true
    else {
      job.satisfied = false
      job.retryAtMs = Number(nowMs)
      job.nextDueMs = Number(nowMs)
    }
  }
  return { state: current, effects: [], nextWakeMs: Number(nowMs) }
}

if (typeof module !== "undefined") module.exports = {
  create: create, reconcile: reconcile, complete: complete, force: force
}

import QtQuick
import "RequestCoordinator.js" as CoordinatorCore
import "SessionCache.js" as SessionCache

// Single execution seam for every bounded network request. Callers submit
// descriptor intents and receive normalized outcomes; transport, queueing,
// priority, deduplication, caching, and helper failures remain private.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  required property string helper
  readonly property int background: 0
  readonly property int interactive: 100
  property var activeDone: null
  property var pendingDescriptor: null
  property var pendingDone: null

  readonly property var implementation: CoordinatorCore.create({
    now: function() { return Date.now() },
    defer: function(callback) { Qt.callLater(callback) },
    sessionCache: SessionCache,
    start: function(descriptor, done) {
      if (transport.running) {
        root.pendingDescriptor = descriptor
        root.pendingDone = done
        return true
      }
      return root.begin(descriptor, done)
    },
    cancel: function() {
      if (root.pendingDescriptor) {
        root.pendingDescriptor = null
        root.pendingDone = null
        return
      }
      transport.cancel()
    }
  })

  function begin(descriptor, done) {
    root.activeDone = done
    return transport.startRequest(descriptor)
  }

  function startPending() {
    if (transport.running || !root.pendingDescriptor) return
    var descriptor = root.pendingDescriptor
    var done = root.pendingDone
    root.pendingDescriptor = null
    root.pendingDone = null
    root.begin(descriptor, done)
  }

  function request(owner, descriptor, priority, callback) {
    return root.implementation.request(owner, descriptor, priority, callback)
  }

  function cancelOwner(owner) {
    root.implementation.cancelOwner(owner)
  }

  function finish(result) {
    var callback = root.activeDone
    root.activeDone = null
    if (callback) callback(result)
  }

  function normalizedError(reason, exitCode) {
    if (exitCode === 2) return "invalid-request"
    if (exitCode === 3 || exitCode === 5) return "response-rejected"
    if (exitCode === 6) return "rate-limited"
    if (reason === "empty-output") return "empty-response"
    return "unavailable"
  }

  BoundedRequest {
    id: transport
    helper: root.helper
    onRunningChanged: if (!running) Qt.callLater(root.startPending)
    onCompleted: function(descriptor, stdout) {
      root.finish({ ok: true, raw: stdout })
    }
    onFailed: function(descriptor, reason, exitCode) {
      root.finish({ ok: false, error: root.normalizedError(reason, exitCode) })
    }
  }
}

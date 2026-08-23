import QtQuick
import Quickshell.Io

// Runs one HTTP helper request under a closed byte/time policy. Callers provide
// only a profile, URL, and opaque token; process details stay inside this seam.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  required property string helper
  readonly property bool running: requestBusy
  property bool requestBusy: false
  property var activeToken: null
  property string collectedStdout: ""
  property bool canceled: false

  signal completed(var token, string stdout)
  signal failed(var token, string reason, int exitCode)

  function policy(profile) {
    switch (String(profile || "")) {
    case "arrival": return { bytes: 1048576, seconds: 8 }
    case "stations": return { bytes: 4194304, seconds: 15 }
    case "geocode": return { bytes: 65536, seconds: 10 }
    case "nearby": return { bytes: 1048576, seconds: 12 }
    case "line-stops": return { bytes: 1048576, seconds: 10 }
    case "line-vehicles": return { bytes: 1048576, seconds: 8 }
    default: return null
    }
  }

  function start(profile, url, token) {
    if (root.requestBusy) return false
    var limits = root.policy(profile)
    var target = String(url || "")
    if (!limits || root.helper === "" || target === "") return false

    root.activeToken = token
    root.collectedStdout = ""
    root.canceled = false
    root.requestBusy = true
    requestProcess.command = [root.helper, String(limits.bytes), String(limits.seconds), target]
    requestProcess.running = true
    return true
  }

  function startRequest(request) {
    if (!request) return false
    return root.start(request.profile, request.url, request)
  }

  function cancel() {
    if (!root.requestBusy) return false
    root.canceled = true
    if (requestProcess.running) requestProcess.running = false
    return true
  }

  function finish(exitCode) {
    var token = root.activeToken
    var stdout = String(root.collectedStdout || output.text || "")
    var wasCanceled = root.canceled
    root.activeToken = null
    root.requestBusy = false
    root.canceled = false

    if (wasCanceled) return
    if (exitCode === 0 && stdout.trim() !== "") {
      root.completed(token, stdout)
    } else {
      root.failed(token, exitCode === 0 ? "empty-output" : "process-exit", exitCode)
    }
  }

  Process {
    id: requestProcess
    running: false
    command: []

    stdout: StdioCollector {
      id: output
      waitForEnd: true
      onStreamFinished: root.collectedStdout = text
    }

    // First-party Process users defer finalization because stream completion
    // and process exit have no guaranteed signal order.
    onExited: function(exitCode) {
      Qt.callLater(function() { root.finish(exitCode) })
    }
  }
}

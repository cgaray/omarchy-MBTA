"use strict"

function derive(input) {
  var state = input || {}
  var loaded = state.loaded === true
  var opened = state.opened === true
  var managing = state.managing === true
  var lineSelected = state.lineSelected === true
  var sideBySide = state.sideBySide === true
  var mode = "hidden"
  if (loaded && opened) {
    if (managing) mode = "manage"
    else if (lineSelected) mode = sideBySide ? "split-line" : "line"
    else mode = "arrivals"
  }
  return { mode: mode }
}

if (typeof module !== "undefined") module.exports = { derive: derive }

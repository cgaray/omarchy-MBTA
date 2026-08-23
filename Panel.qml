import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Mbta.js" as Mbta

Panel {
  id: root
  moduleName: "io.github.cgaray.mbta"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: popout coordination and switchPanelFrom both compare against it.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Data feed lives on the always-mounted bar widget; this panel only renders it.
  readonly property var feed: hostWidget || null
  readonly property var board: feed && feed.board ? feed.board : null
  readonly property real nowMs: feed ? feed.nowMs : 0
  readonly property bool loading: feed ? feed.loading : false
  readonly property string errorText: feed ? feed.errorText : ""
  readonly property bool scheduledMode: board ? !board.realtime : false
  readonly property var configuredStopIds: feed && feed.configuredStopIds ? feed.configuredStopIds : []
  readonly property string activeLineKey: feed ? feed.activeLineKey : ""
  readonly property bool lineVisible: feed ? feed.lineVisible : false

  // The station list downloads in the background; when it lands, re-run
  // whatever query the user already typed instead of leaving a stale "no match".
  readonly property bool stationsReady: feed && feed.stationsCache !== null
  onStationsReadyChanged: {
    if (root.managing && root.pickerMode === "name" && root.stationQuery !== "")
      searchDebounce.restart()
  }

  // ---- Station picker state
  property bool managing: false
  property string pickerMode: "name" // "name" | "nearby"
  property string stationQuery: ""
  property var stationResults: []
  property int resultIndex: -1

  Timer {
    id: searchDebounce
    interval: 120
    onTriggered: root.runStationSearch()
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    if (feed) feed.refreshNow()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    if (feed) feed.refreshNow()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.managing) stopManaging()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function startManaging() {
    root.managing = true
    // Resume in whichever mode the user picked last time.
    var lastMode = feed ? String(feed.readSetting("pickerMode", "") || "") : ""
    if (lastMode === "nearby" || lastMode === "name") root.pickerMode = lastMode
    root.stationQuery = ""
    root.stationResults = []
    root.resultIndex = -1
    if (feed && root.pickerMode === "name") feed.ensureStations()
    Qt.callLater(function() {
      if (root.pickerMode === "name") stationField.forceActiveFocus()
      else addressField.forceActiveFocus()
    })
  }

  function stopManaging() {
    root.managing = false
    root.stationQuery = ""
    root.stationResults = []
    root.resultIndex = -1
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function setPickerMode(mode) {
    if (root.pickerMode === mode) return
    root.pickerMode = mode
    root.stationQuery = ""
    root.stationResults = []
    root.resultIndex = -1
    if (mode === "name" && feed) feed.ensureStations()
    Qt.callLater(function() {
      if (mode === "name") stationField.forceActiveFocus()
      else addressField.forceActiveFocus()
    })
  }

  function runStationSearch() {
    if (!feed) return
    root.stationResults = feed.searchStations(root.stationQuery)
    root.resultIndex = root.stationResults.length > 0 ? 0 : -1
  }

  function triggerNearbySearch() {
    if (!feed) return
    var address = addressField.text
    var radiusKm = parseRadius()
    if (address.trim() === "") return useMyLocation()

    var started = feed.findNearby(address, radiusKm)
    // Remember the commute for next time.
    if (started) feed.updateSettings({ lastAddress: address, lastRadiusKm: radiusKm, pickerMode: "nearby" })
  }

  function useMyLocation() {
    if (!feed) return
    var radiusKm = parseRadius()
    feed.useMyLocation(radiusKm)
    feed.updateSettings({ lastRadiusKm: radiusKm, pickerMode: "nearby" })
  }

  function parseRadius() {
    var radiusKm = parseFloat(radiusField.text.replace(",", "."))
    if (isNaN(radiusKm) || radiusKm <= 0) radiusKm = 1
    radiusKm = Math.min(20, radiusKm)
    radiusField.text = String(radiusKm)
    return radiusKm
  }

  function activeResultCount() {
    return root.pickerMode === "name" ? root.stationResults.length : (feed ? feed.nearbyResults.length : 0)
  }

  function pickResult(at) {
    if (!feed || at < 0 || at >= activeResultCount()) return
    var stationId = root.pickerMode === "name"
      ? root.stationResults[at].id
      : feed.nearbyResults[at].id
    feed.toggleStop(stationId)
    if (root.pickerMode === "name") searchDebounce.restart()
  }

  function moveResultSelection(delta) {
    var count = activeResultCount()
    if (!count) return
    var next = root.resultIndex + delta
    if (next < 0) next = 0
    if (next > count - 1) next = count - 1
    root.resultIndex = next
  }

  function updatedLabel() {
    if (!feed || feed.lastUpdated.getTime() <= 0) return ""
    return Qt.formatDateTime(feed.lastUpdated, "HH:mm:ss")
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.lineVisible && !root.managing ? 820 : 430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.managing && root.stationQuery !== "") {
          root.stationQuery = ""
          searchDebounce.restart()
        } else if (root.managing) {
          root.stopManaging()
        } else {
          root.close()
        }
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    Column {
      id: content
      width: parent.width
      spacing: Style.space(10)

      // ---- Header: brand mark, title, live refresh.
      Row {
        width: parent.width
        spacing: Style.space(10)

        Rectangle {
          width: Style.font.heading + Style.space(8)
          height: width
          radius: height / 2
          color: "#DA291C"
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            text: "T"
            color: "#FFFFFF"
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: 1

          Text {
            text: "MBTA"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            text: {
              if (root.errorText !== "") return root.errorText
              if (root.loading) return "Updating…"
              if (!root.board) return "Waiting for data…"
              var stops = root.board.stops.filter(function(s) { return s.groups.length > 0 }).length
              return stops > 0
                ? stops + (stops === 1 ? " station" : " stations") + (root.scheduledMode ? " · scheduled times" : "")
                : "No departures found"
            }
            color: root.errorText !== "" ? Color.urgent : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Item { width: 1; height: 1 } // spring

        Rectangle {
          width: Style.space(26)
          height: Style.space(26)
          radius: Math.min(4, Style.cornerRadius)
          color: refreshArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            text: "⟳"
            color: root.loading ? Color.muted : root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.title

            RotationAnimator on rotation {
              running: root.loading
              from: 0; to: 360
              duration: 900
              loops: Animation.Infinite
            }
          }

          MouseArea {
            id: refreshArea
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.feed) root.feed.refreshNow()
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.alpha(Color.foreground, 0.12)
      }

      // ---- Departure board and one shared line-detail pane.
      Row {
        id: boardLayout
        visible: !root.managing
        width: parent.width
        spacing: sideBySide ? Style.space(14) : 0
        readonly property bool sideBySide: root.lineVisible && width >= Style.space(680)

        Item {
          id: arrivalsPane
          visible: !root.lineVisible || boardLayout.sideBySide
          width: visible ? (boardLayout.sideBySide ? Math.round((parent.width - boardLayout.spacing) * 0.48) : parent.width) : 0
          height: visible ? Math.min(arrivalsContent.implicitHeight, Style.space(480)) : 0
          implicitHeight: height

          Flickable {
            id: arrivalsViewport
            anchors.fill: parent
            anchors.rightMargin: arrivalsScrollTrack.visible ? Style.space(8) : 0
            contentWidth: width
            contentHeight: arrivalsContent.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: arrivalsContent
              width: parent.width
              spacing: Style.space(12)

              Repeater {
                model: root.board ? root.board.stops : []

                Column {
                  id: stopSection
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(7)

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      text: stopSection.modelData.name
                      textFormat: Text.PlainText
                      color: root.barForeground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                      width: parent.width
                      elide: Text.ElideRight
                    }
                  }

                  Repeater {
                    model: stopSection.modelData.groups

                    ArrivalRow {
                      required property var modelData
                      width: parent.width
                      group: modelData
                      nowMs: root.nowMs
                      foreground: root.barForeground
                      selected: root.lineVisible && root.activeLineKey === modelData.key
                        && root.feed.activeLineStopId === modelData.stopId
                      onActivated: if (root.feed) root.feed.toggleLine(modelData)
                    }
                  }

                  Text {
                    visible: stopSection.modelData.groups.length === 0
                    text: root.scheduledMode ? "No departures" : "No live predictions"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.italic: true
                  }
                }
              }

              Text {
                visible: !!root.board && root.board.stops.every(function(s) { return s.groups.length === 0 })
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "No service at your stations right now.\nAdd more stations below or check mbta.com."
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Rectangle {
            id: arrivalsScrollTrack
            visible: arrivalsViewport.contentHeight > arrivalsViewport.height + 1
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(3)
            radius: width / 2
            color: Qt.alpha(root.barForeground, 0.12)

            Rectangle {
              width: parent.width
              height: Math.max(Style.space(24), parent.height * arrivalsViewport.height / arrivalsViewport.contentHeight)
              y: (parent.height - height) * arrivalsViewport.contentY
                / (arrivalsViewport.contentHeight - arrivalsViewport.height)
              radius: width / 2
              color: Color.accent
            }
          }
        }

        Rectangle {
          visible: boardLayout.sideBySide
          width: visible ? 1 : 0
          height: Math.max(arrivalsPane.implicitHeight, linePane.implicitHeight)
          color: Qt.alpha(root.barForeground, 0.12)
        }

        Column {
          id: linePane
          visible: root.lineVisible
          width: visible ? (boardLayout.sideBySide
            ? parent.width - arrivalsPane.width - boardLayout.spacing * 2 - 1
            : parent.width) : 0
          spacing: Style.space(9)

          Row {
            width: parent.width
            spacing: Style.space(8)

            RouteBadge {
              anchors.verticalCenter: parent.verticalCenter
              badgeLabel: root.feed && root.feed.activeLineBadge ? root.feed.activeLineBadge.label : ""
              badgeColorHex: root.feed && root.feed.activeLineBadge ? root.feed.activeLineBadge.color : "7C878E"
              badgeTextHex: root.feed && root.feed.activeLineBadge ? root.feed.activeLineBadge.textColor : "FFFFFF"
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(0, parent.width - x - pinLineButton.width - closeLineButton.width - parent.spacing * 2)
              text: root.feed ? "toward " + root.feed.activeLineHeadsign : ""
              textFormat: Text.PlainText
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Rectangle {
              id: pinLineButton
              anchors.verticalCenter: parent.verticalCenter
              readonly property bool pinned: root.feed && root.feed.pinnedLineKey === root.feed.activeLinePinKey
              width: pinLineLabel.implicitWidth + Style.space(12)
              height: Style.space(24)
              radius: height / 2
              color: pinned ? Qt.alpha(Color.accent, 0.20)
                : (pinLineArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent")
              border.width: 1
              border.color: pinned ? Color.accent : Qt.alpha(root.barForeground, 0.20)

              Text {
                id: pinLineLabel
                anchors.centerIn: parent
                text: parent.pinned ? "Pinned" : "Pin"
                color: parent.pinned ? Color.accent : root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: parent.pinned
              }

              MouseArea {
                id: pinLineArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.feed) root.feed.togglePinnedLine()
              }
            }

            Rectangle {
              id: closeLineButton
              anchors.verticalCenter: parent.verticalCenter
              width: closeLineLabel.implicitWidth + Style.space(12)
              height: Style.space(24)
              radius: height / 2
              color: closeLineArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"

              Text {
                id: closeLineLabel
                anchors.centerIn: parent
                text: boardLayout.sideBySide ? "×" : "← Arrivals"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: closeLineArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.feed) root.feed.closeLine()
              }
            }
          }

          StripMap {
            width: parent.width
            routeLabel: root.feed && root.feed.activeLineBadge ? root.feed.activeLineBadge.label : ""
            routeColorHex: root.feed && root.feed.activeLineBadge ? root.feed.activeLineBadge.color : "7C878E"
            headsign: root.feed ? root.feed.activeLineHeadsign : ""
            selectedStopId: root.feed ? root.feed.activeLineStopId : ""
            stops: root.feed ? root.feed.lineStops : []
            vehicles: root.feed ? root.feed.lineVehicles : []
            loading: root.feed ? root.feed.lineLoading : false
            errorText: root.feed ? root.feed.lineError : ""
            foreground: root.barForeground
          }
        }
      }

      // ---- Station picker (manage view)
      Column {
        visible: root.managing
        width: parent.width
        spacing: Style.space(9)

        // Mode toggle: search by name, or scan around an address/point.
        Row {
          spacing: Style.space(4)

          Repeater {
            model: [
              { mode: "name", label: "By name" },
              { mode: "nearby", label: "Near address" }
            ]

            Rectangle {
              id: modeTab
              required property var modelData
              property bool active: root.pickerMode === modelData.mode

              width: modeLabel.implicitWidth + Style.space(16)
              height: Style.space(22)
              radius: height / 2
              color: active ? Style.selectedFillFor(root.barForeground, Color.accent)
                            : (modeArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent")

              Text {
                id: modeLabel
                anchors.centerIn: parent
                text: modeTab.modelData.label
                color: modeTab.active ? Color.accent : root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: modeTab.active
              }

              MouseArea {
                id: modeArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: root.setPickerMode(modeTab.modelData.mode)
              }
            }
          }
        }

        // Name-search mode.
        Column {
          visible: root.pickerMode === "name"
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: stationField
            width: parent.width
            placeholderText: "Search stations — e.g. Davis, North Station"
            foreground: root.barForeground

            onTextChanged: {
              root.stationQuery = text
              searchDebounce.restart()
            }

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (text !== "") { text = ""; searchDebounce.restart() }
                else root.stopManaging()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.moveResultSelection(1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.moveResultSelection(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.pickResult(root.resultIndex)
                event.accepted = true
              }
            }
          }

          StationResultsView {
            width: parent.width
            results: root.stationResults
            selectedIndex: root.resultIndex
            configuredStopIds: root.configuredStopIds
            emptyText: root.stationQuery !== "" && root.stationResults.length === 0
              ? (root.feed && root.feed.stationsLoading ? "Loading stations…" : "No stations match") : ""
            onPick: function(at) { root.pickResult(at) }
            onHoveredRow: function(at) { root.resultIndex = at }
          }
        }

        // Nearby mode: address or raw coordinates plus a radius in km.
        Column {
          visible: root.pickerMode === "nearby"
          width: parent.width
          spacing: Style.space(8)

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: addressField
              width: Math.max(Style.space(120), parent.width - locateButton.width - radiusWrap.width - findButton.width - parent.spacing * 3)
              placeholderText: "Address, place, or lat,lon"
              foreground: root.barForeground
              text: root.feed ? String(root.feed.readSetting("lastAddress", "") || "") : ""

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  if (text !== "") { text = "" }
                  else root.stopManaging()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.triggerNearbySearch()
                  event.accepted = true
                }
              }
            }

            Item {
              id: radiusWrap
              width: Style.space(44)
              height: addressField.height
              anchors.verticalCenter: parent.verticalCenter

              TextField {
                id: radiusField
                anchors.fill: parent
                placeholderText: "km"
                foreground: root.barForeground
                text: root.feed ? String(root.feed.readSetting("lastRadiusKm", 1)) : "1"

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.triggerNearbySearch()
                    event.accepted = true
                  }
                }
              }
            }

            Rectangle {
              id: locateButton
              width: locateLabel.implicitWidth + Style.space(12)
              height: addressField.height * 0.86
              radius: Math.min(4, Style.cornerRadius)
              anchors.verticalCenter: parent.verticalCenter
              color: locateArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : Style.normalFillFor(root.barForeground, Color.accent)

              Text {
                id: locateLabel
                anchors.centerIn: parent
                text: "⌖ My location"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: locateArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: root.useMyLocation()
              }
            }

            Rectangle {
              id: findButton
              width: findLabel.implicitWidth + Style.space(14)
              height: addressField.height * 0.86
              radius: Math.min(4, Style.cornerRadius)
              anchors.verticalCenter: parent.verticalCenter
              color: findArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : Style.selectedAccentFill

              Text {
                id: findLabel
                anchors.centerIn: parent
                text: "Find"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: findArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: root.triggerNearbySearch()
              }
            }
          }

          Text {
            width: parent.width
            text: {
              if (!root.feed) return ""
              if (root.feed.locating) return "Finding location…"
              if (root.feed.nearbyLoading) return "Scanning stops…"
              if (root.feed.nearbyError !== "") return root.feed.nearbyError
              if (root.feed.lastOrigin) return "Origin: " + root.feed.lastOrigin.source
              return "Enter an address, paste coordinates, or use ⌖"
            }
            textFormat: Text.PlainText
            color: root.feed && root.feed.nearbyError !== "" ? Color.urgent : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          StationResultsView {
            width: parent.width
            results: root.feed ? root.feed.nearbyResults : []
            selectedIndex: root.resultIndex
            configuredStopIds: root.configuredStopIds
            showDistances: true
            onPick: function(at) { root.pickResult(at) }
            onHoveredRow: function(at) { root.resultIndex = at }
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.configuredStopIds

            Rectangle {
              id: chip
              required property string modelData
              property string chipName: {
                if (!root.board) return modelData
                for (var i = 0; i < root.board.stops.length; i++)
                  if (root.board.stops[i].id === modelData) return root.board.stops[i].name
                return modelData
              }

              height: Style.space(22)
              width: chipNameLabel.implicitWidth + removeMark.width + Style.space(16)
              radius: height / 2
              color: Qt.alpha(Color.accent, 0.14)

              Row {
                anchors.centerIn: parent
                spacing: Style.space(5)

                Text {
                  id: chipNameLabel
                  text: chip.chipName
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: removeMark
                  text: "✕"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.feed) root.feed.toggleStop(chip.modelData)
              }
            }
          }

          Rectangle {
            visible: root.configuredStopIds.length === 0
            height: Style.space(20)
            width: emptyHint.implicitWidth + Style.space(12)
            radius: height / 2
            color: "transparent"

            Text {
              id: emptyHint
              anchors.centerIn: parent
              text: "No stations yet — search above"
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.alpha(Color.foreground, 0.12)
      }

      // ---- Footer: schedule-mode note + station manager toggle.
      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (root.scheduledMode) return "Showing scheduled times (no live data)"
            var stamp = root.updatedLabel()
            return stamp !== "" ? "Updated " + stamp : ""
          }
          color: root.scheduledMode ? Color.muted : Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Item { width: 1; height: 1 } // spring

        Rectangle {
          height: Style.space(22)
          width: manageLabel.implicitWidth + Style.space(14)
          radius: Math.min(4, Style.cornerRadius)
          color: manageArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent) : Style.normalFillFor(root.barForeground, Color.accent)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: manageLabel
            anchors.centerIn: parent
            text: root.managing ? "Done" : "Manage stations"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: root.managing
          }

          MouseArea {
            id: manageArea
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.managing ? root.stopManaging() : root.startManaging()
          }
        }
      }
    }
  }
}

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "PanelActivity.js" as PanelActivity

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
  readonly property var activity: PanelActivity.derive({
    loaded: true,
    opened: root.opened,
    managing: root.managing,
    lineSelected: root.lineVisible,
    sideBySide: boardLayout.sideBySide
  })

  // Read-only view compatibility over the nonvisual picker state machine.
  readonly property bool managing: panelSession.managing
  readonly property string pickerMode: panelSession.pickerMode
  readonly property string stationQuery: panelSession.stationQuery
  readonly property var stationResults: panelSession.stationResults
  readonly property int resultIndex: panelSession.resultIndex

  PanelSession {
    id: panelSession
    feed: root.feed
    preferences: root.feed ? root.feed.mbtaSettings : null
  }

  Connections {
    target: panelSession
    function onFocusIntent(target) {
      Qt.callLater(function() {
        if (target === "station") stationField.forceActiveFocus()
        else if (target === "address") addressField.forceActiveFocus()
        else keyCatcher.forceActiveFocus()
      })
    }
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    if (feed) {
      feed.refreshIfStale()
    }
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    if (feed) {
      feed.refreshIfStale()
    }
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.managing) panelSession.stopManaging()
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
    contentWidth: panel.fittedContentWidth(Style.space(root.lineVisible ? 820 : 430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: {
        if (root.managing && root.stationQuery !== "") {
          panelSession.clearStationQuery()
        } else if (root.managing) {
          panelSession.stopManaging()
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

      // ---- Header: brand, live state, metadata, and primary controls.
      Row {
        width: parent.width
        spacing: Style.space(10)

        Rectangle {
          width: Style.space(34)
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
          width: Math.max(0, parent.width - x - manageButton.width - refreshButton.width
            - parent.spacing * 2)
          spacing: 2

          Row {
            spacing: Style.space(7)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "MBTA"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              font.letterSpacing: 0.4
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: liveState.implicitWidth + Style.space(13)
              height: Style.space(18)
              radius: height / 2
              color: Qt.alpha(root.scheduledMode ? Color.muted : "#42D392", 0.11)
              border.width: 1
              border.color: Qt.alpha(root.scheduledMode ? Color.muted : "#42D392", 0.28)

              Row {
                id: liveState
                anchors.centerIn: parent
                spacing: Style.space(4)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(5)
                  height: width
                  radius: width / 2
                  color: root.scheduledMode ? Color.muted : "#42D392"
                }

                Text {
                  text: root.loading ? "SYNCING" : (root.scheduledMode ? "SCHEDULED" : "LIVE")
                  color: root.scheduledMode ? Color.muted : "#42D392"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 0.7
                }
              }
            }
          }

          Text {
            text: {
              if (root.errorText !== "") return root.errorText
              if (!root.board) return "Waiting for data…"
              var stops = root.board.stops.filter(function(s) { return s.groups.length > 0 }).length
              var stationLabel = stops > 0
                ? stops + (stops === 1 ? " STATION" : " STATIONS") : "NO DEPARTURES"
              var stamp = root.updatedLabel()
              return stamp !== "" ? stationLabel + "  ·  UPDATED " + stamp : stationLabel
            }
            color: root.errorText !== "" ? Color.urgent : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.35
          }
        }

        Rectangle {
          id: manageButton
          height: Style.space(26)
          width: manageLabel.implicitWidth + Style.space(16)
          radius: height / 2
          color: root.managing ? Qt.alpha(Color.accent, 0.16)
            : (manageArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent)
              : Qt.alpha(root.barForeground, 0.045))
          border.width: 1
          border.color: root.managing ? Qt.alpha(Color.accent, 0.42)
            : Qt.alpha(root.barForeground, 0.12)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: manageLabel
            anchors.centerIn: parent
            text: root.managing ? "Done" : "Manage stations"
            color: root.managing ? Color.accent : root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: root.managing
          }

          MouseArea {
            id: manageArea
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: root.managing ? panelSession.stopManaging() : panelSession.startManaging()
          }
        }

        Rectangle {
          id: refreshButton
          width: Style.space(28)
          height: Style.space(26)
          radius: height / 2
          color: refreshArea.containsMouse ? Style.hoverFillFor(root.barForeground, Color.accent)
            : Qt.alpha(root.barForeground, 0.045)
          border.width: 1
          border.color: Qt.alpha(root.barForeground, 0.12)
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
        color: Qt.alpha(Color.foreground, 0.08)
      }

      // ---- Departure board and one shared line-detail pane.
      Row {
        id: boardLayout
        visible: !root.managing
        width: parent.width
        spacing: sideBySide ? Style.space(16) : 0
        readonly property bool sideBySide: width >= Style.space(680)

        Item {
          id: arrivalsPane
          visible: !root.lineVisible || boardLayout.sideBySide
          width: visible ? (boardLayout.sideBySide ? Math.round((parent.width - boardLayout.spacing) * 0.45) : parent.width) : 0
          height: visible ? Math.min(arrivalsContent.implicitHeight, Style.space(500)) : 0
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
              spacing: Style.space(8)

              Repeater {
                model: root.board ? root.board.stops : []

                Item {
                  id: stopSection
                  required property var modelData
                  width: parent.width
                  height: sectionContent.implicitHeight + Style.space(12)

                  Rectangle {
                    anchors.fill: parent
                    radius: Math.min(7, Style.cornerRadius)
                    color: Qt.alpha(root.barForeground, 0.026)
                    border.width: 1
                    border.color: Qt.alpha(root.barForeground, 0.045)
                  }

                  Column {
                    id: sectionContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(6)
                    spacing: Style.space(3)

                    Row {
                      width: parent.width
                      spacing: Style.space(6)

                      Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(5)
                        height: width
                        radius: width / 2
                        color: Qt.alpha(root.barForeground, 0.42)
                      }

                      Text {
                        width: Math.max(0, parent.width - routeCountLabel.width - parent.spacing * 2
                          - Style.space(5))
                        text: stopSection.modelData.name.toUpperCase()
                        textFormat: Text.PlainText
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        font.letterSpacing: 0.85
                        elide: Text.ElideRight
                      }

                      Text {
                        id: routeCountLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: stopSection.modelData.groups.length + (stopSection.modelData.groups.length === 1
                          ? " ROUTE" : " ROUTES")
                        color: Qt.alpha(root.barForeground, 0.50)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 0.45
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
          color: Qt.alpha(root.barForeground, 0.07)
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
                onClicked: panelSession.togglePinnedLine()
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
                onClicked: panelSession.setPickerMode(modeTab.modelData.mode)
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
              panelSession.setStationQuery(text)
            }

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (text !== "") { text = ""; panelSession.clearStationQuery() }
                else panelSession.stopManaging()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                panelSession.moveResultSelection(1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                panelSession.moveResultSelection(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                panelSession.pickResult(root.resultIndex)
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
            onPick: function(at) { panelSession.pickResult(at) }
            onHoveredRow: function(at) { panelSession.resultIndex = at }
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
              placeholderText: "Your address, place, or lat,lon"
              foreground: root.barForeground
              text: panelSession.addressText
              onTextChanged: panelSession.addressText = text

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  if (text !== "") { text = "" }
                  else panelSession.stopManaging()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  panelSession.triggerNearbySearch()
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
                text: panelSession.radiusText
                onTextChanged: panelSession.radiusText = text

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    panelSession.triggerNearbySearch()
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
                text: "⌖ Saved location"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: locateArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: panelSession.useSavedLocation()
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
                onClicked: panelSession.triggerNearbySearch()
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
            onPick: function(at) { panelSession.pickResult(at) }
            onHoveredRow: function(at) { panelSession.resultIndex = at }
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
                  textFormat: Text.PlainText
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
                onClicked: panelSession.toggleStop(chip.modelData)
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

    }
  }
}

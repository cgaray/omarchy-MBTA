import QtQuick
import qs.Commons

Item {
  id: root

  property string routeLabel: ""
  property string routeColorHex: "7C878E"
  property string headsign: ""
  property string selectedStopId: ""
  property var stops: []
  property var vehicles: []
  property bool loading: false
  property string errorText: ""
  property color foreground: Color.foreground
  property int activeVehicleIndex: -1
  onVehiclesChanged: activeVehicleIndex = -1
  onStopsChanged: activeVehicleIndex = -1

  function stopNameFor(stopId) {
    for (var i = 0; i < root.stops.length; i++)
      if (String(root.stops[i].id) === String(stopId)) return String(root.stops[i].name)
    return ""
  }

  function statusText(status) {
    if (status === "STOPPED_AT") return "At stop"
    if (status === "INCOMING_AT") return "Approaching"
    if (status === "IN_TRANSIT_TO") return "Incoming at"
    return "Live"
  }

  readonly property color routeColor: routeColorHex.length === 6 ? ("#" + routeColorHex) : "#7C878E"
  readonly property real rowHeight: Style.space(34)
  readonly property bool blockingError: root.errorText !== "" && root.stops.length === 0

  implicitHeight: header.implicitHeight + Style.space(8) + Math.min(Style.space(310), stripContent.height)

  Column {
    anchors.fill: parent
    spacing: Style.space(8)

    Row {
      id: header
      width: parent.width
      spacing: Style.space(7)

      Text {
        text: root.loading ? "Loading route…" : (root.vehicles.length + (root.vehicles.length === 1 ? " live vehicle" : " live vehicles"))
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: stripViewport.contentHeight > stripViewport.height
        width: Math.max(0, parent.width - x)
        text: "↕  Scroll for all stops"
        color: root.routeColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        visible: root.errorText !== "" && !root.blockingError
        width: Math.max(0, parent.width - x)
        text: root.errorText
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Flickable {
      id: stripViewport
      width: parent.width
      height: Math.min(Style.space(310), stripContent.height)
      contentWidth: width
      contentHeight: stripContent.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Item {
        id: stripContent
        width: stripViewport.width
        height: root.blockingError ? errorLabel.implicitHeight : Math.max(root.rowHeight, root.stops.length * root.rowHeight)

        Text {
          id: errorLabel
          visible: root.blockingError
          text: root.errorText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.blockingError ? [] : root.stops

          Item {
            required property int index
            required property var modelData
            readonly property bool selectedStop: String(modelData.id) === root.selectedStopId
            x: 0
            y: index * root.rowHeight
            width: stripContent.width
            height: root.rowHeight

            Rectangle {
              x: Style.space(15)
              y: root.rowHeight / 2
              width: Style.space(3)
              height: index < root.stops.length - 1 ? root.rowHeight : 0
              color: root.routeColor
            }

            Rectangle {
              x: Style.space(11) - (parent.selectedStop ? Style.space(2) : 0)
              y: root.rowHeight / 2 - width / 2
              width: parent.selectedStop ? Style.space(15) : Style.space(11)
              height: width
              radius: width / 2
              color: parent.selectedStop ? root.routeColor : Qt.alpha(root.foreground, 0.20)
              border.width: 2
              border.color: root.routeColor
            }

            Text {
              x: Style.space(32)
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - x
              text: modelData.name
              textFormat: Text.PlainText
              color: parent.selectedStop ? root.routeColor : root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: parent.selectedStop
              elide: Text.ElideRight
            }
          }
        }

        Repeater {
          model: root.errorText === "" ? root.vehicles : []

          Rectangle {
            id: vehicleMarker
            required property int index
            required property var modelData
            x: Style.space(7)
            y: root.rowHeight / 2 - height / 2 + modelData.fraction * Math.max(0, stripContent.height - root.rowHeight)
            width: Style.space(19)
            height: width
            radius: width / 2
            color: root.routeColor
            border.width: root.activeVehicleIndex === index ? 3 : 2
            border.color: root.foreground

            Rectangle {
              anchors.centerIn: parent
              width: parent.width
              height: width
              radius: width / 2
              color: "transparent"
              border.width: 1
              border.color: root.routeColor
              scale: 1.35
              opacity: 0.24
              z: -1
            }

            Text {
              anchors.centerIn: parent
              text: "›"
              color: "#FFFFFF"
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeVehicleIndex = root.activeVehicleIndex === vehicleMarker.index
                ? -1 : vehicleMarker.index

              Accessible.role: Accessible.Button
              Accessible.name: (vehicleMarker.modelData.label !== "" ? vehicleMarker.modelData.label : "Vehicle")
                + ", " + root.statusText(vehicleMarker.modelData.status) + " "
                + root.stopNameFor(vehicleMarker.modelData.stopId)
              Accessible.onPressAction: root.activeVehicleIndex = root.activeVehicleIndex === vehicleMarker.index
                ? -1 : vehicleMarker.index
            }
          }
        }

        Rectangle {
          id: vehicleBubble
          readonly property bool shown: root.activeVehicleIndex >= 0
            && root.activeVehicleIndex < root.vehicles.length
          readonly property real markerY: shown
            ? root.rowHeight / 2 - height / 2
              + root.vehicles[root.activeVehicleIndex].fraction * Math.max(0, stripContent.height - root.rowHeight)
            : 0
          visible: shown
          x: Style.space(34)
          y: Math.max(Style.space(4), Math.min(stripContent.height - height - Style.space(4), markerY))
          width: bubbleContent.implicitWidth + Style.space(16)
          height: bubbleContent.implicitHeight + Style.space(10)
          radius: Math.min(6, Style.cornerRadius)
          color: Qt.alpha(root.routeColor, 0.18)
          border.width: 1
          border.color: root.routeColor

          Column {
            id: bubbleContent
            anchors.centerIn: parent
            spacing: 1

            Text {
              text: vehicleBubble.shown && root.vehicles[root.activeVehicleIndex].label !== ""
                ? root.vehicles[root.activeVehicleIndex].label : (vehicleBubble.shown ? "Vehicle" : "")
              textFormat: Text.PlainText
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              text: vehicleBubble.shown
                ? root.statusText(root.vehicles[root.activeVehicleIndex].status) + " "
                  + root.stopNameFor(root.vehicles[root.activeVehicleIndex].stopId) : ""
              textFormat: Text.PlainText
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            anchors.fill: parent
            onClicked: root.activeVehicleIndex = -1
          }
        }
      }
    }
  }
}

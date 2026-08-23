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

  readonly property color routeColor: routeColorHex.length === 6 ? ("#" + routeColorHex) : "#7C878E"
  readonly property real rowHeight: Style.space(34)

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
        height: root.errorText !== "" ? errorLabel.implicitHeight : Math.max(root.rowHeight, root.stops.length * root.rowHeight)

        Text {
          id: errorLabel
          visible: root.errorText !== ""
          text: root.errorText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.errorText === "" ? root.stops : []

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
            required property int index
            required property var modelData
            property real pulsePhase: 0
            x: Style.space(7)
            y: root.rowHeight / 2 - height / 2 + modelData.fraction * Math.max(0, stripContent.height - root.rowHeight)
            width: Style.space(19)
            height: width
            radius: width / 2
            color: root.routeColor
            border.width: 2
            border.color: root.foreground

            Rectangle {
              anchors.centerIn: parent
              width: parent.width
              height: width
              radius: width / 2
              color: "transparent"
              border.width: 1
              border.color: root.routeColor
              scale: 1 + parent.pulsePhase * 0.5
              opacity: 0.32 * (1 - parent.pulsePhase)
              z: -1
            }

            SequentialAnimation on pulsePhase {
              running: root.visible
              loops: Animation.Infinite
              PauseAnimation { duration: index * 160 }
              NumberAnimation { from: 0; to: 1; duration: 1250; easing.type: Easing.OutCubic }
              PauseAnimation { duration: 650 }
            }

            Text {
              anchors.centerIn: parent
              text: "›"
              color: "#FFFFFF"
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }
        }
      }
    }
  }
}

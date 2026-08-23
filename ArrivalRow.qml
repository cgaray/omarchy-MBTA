import QtQuick
import qs.Commons
import "Mbta.js" as Mbta

// One departure-board line: route bullet, headsign, then countdown chips.
// Pure presentation — the group object comes fully built from Mbta.js and
// nothing here touches processes, settings, or files.
Item {
  id: root

  property var group: null
  property real nowMs: 0
  property color foreground: Color.foreground
  property color accentColor: Color.accent
  property color mutedColor: Color.muted
  property bool selected: false

  signal activated()

  property real spacing: Style.space(10)
  height: badge.height

  Rectangle {
    anchors.fill: parent
    anchors.margins: -Style.space(4)
    radius: Math.min(4, Style.cornerRadius)
    color: root.selected ? Qt.alpha(root.accentColor, 0.10) : "transparent"
  }

  Row {
    id: contentRow
    anchors.fill: parent
    spacing: root.spacing

    RouteBadge {
      id: badge
      anchors.verticalCenter: parent.verticalCenter
      badgeLabel: root.group ? root.group.badge.label : ""
      badgeColorHex: root.group ? root.group.badge.color : ""
      badgeTextHex: root.group ? root.group.badge.textColor : ""
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, root.width - badge.width - chipsRow.width - toggleIndicator.width - root.spacing * 3)
      text: root.group && root.group.headsign !== "" ? root.group.headsign : "Departures"
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Row {
      id: chipsRow
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(7)

      Repeater {
        model: root.group ? root.group.times : []

        Text {
          id: chip
          required property int index
          required property var modelData

          readonly property string label: modelData && root.nowMs > 0
            ? Mbta.countdownLabel(modelData.ms - root.nowMs)
            : ""

          anchors.verticalCenter: parent.verticalCenter
          text: label
          color: index === 0 ? root.accentColor : root.mutedColor
          font.family: Style.font.family
          font.pixelSize: index === 0 ? Style.font.body : Style.font.bodySmall
          font.bold: index === 0
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !!root.group && root.group.more > 0
        text: root.group ? "+" + root.group.more : ""
        color: root.mutedColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      id: toggleIndicator
      anchors.verticalCenter: parent.verticalCenter
      text: root.selected ? "▴" : "▾"
      color: root.mutedColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    anchors.fill: parent
    anchors.margins: -Style.space(4)
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}

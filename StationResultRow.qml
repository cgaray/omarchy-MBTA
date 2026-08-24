import QtQuick
import qs.Commons

// One station-picker result row (name search and nearby search share it).
// Pure presentation: props in, pick/hover signals out.
Rectangle {
  id: root

  property var station: null
  property int at: -1
  property bool selected: false
  property bool picked: false
  property string distanceText: ""

  signal pick(int indexAt)
  signal hoveredRow(int indexAt)

  width: parent ? parent.width : 0
  height: Style.space(24)
  radius: Math.min(4, Style.cornerRadius)
  color: selected ? Style.selectedFillFor(Color.foreground, Color.accent)
                  : (picked ? Qt.alpha(Color.accent, 0.10) : "transparent")

  Row {
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(8)

    Text {
      width: parent.width - parent.spacing * 2
              - (distanceLabel.visible ? distanceLabel.width : 0)
              - addMark.width
      text: root.station
            ? root.station.name + (root.station.municipality !== ""
                && root.station.municipality !== root.station.name
                ? "  ·  " + root.station.municipality : "")
            : ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: distanceLabel
      visible: root.distanceText !== ""
      text: root.distanceText
      textFormat: Text.PlainText
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: addMark
      text: root.picked ? "✓" : "+"
      color: root.picked ? Color.accent : Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    hoverEnabled: true
    onEntered: root.hoveredRow(root.at)
    onClicked: root.pick(root.at)

    Accessible.role: Accessible.Button
    Accessible.name: (root.station ? root.station.name
        + (root.station.municipality !== "" && root.station.municipality !== root.station.name
          ? ", " + root.station.municipality : "") : "")
      + (distanceText !== "" ? ", " + distanceText : "")
      + (picked ? ", added" : "")
    Accessible.onPressAction: root.pick(root.at)
  }
}

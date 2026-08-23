import QtQuick
import qs.Commons

// Colored MBTA route bullet: a rounded chip carrying the API's route color
// with contrast-safe text. Pure presentation — every visual value arrives as
// a property.
Rectangle {
  id: root

  property string badgeLabel: ""
  property string badgeColorHex: "7C878E"
  property string badgeTextHex: "FFFFFF"
  property real fontSize: Style.font.bodySmall

  readonly property color fillColor: root.badgeColorHex.length === 6 ? ("#" + root.badgeColorHex) : "#7C878E"
  readonly property color textColor: root.badgeTextHex.length === 6 ? ("#" + root.badgeTextHex) : "#FFFFFF"

  width: Math.max(height, label.implicitWidth + Style.space(10))
  height: Math.round(Style.font.body * 1.75)
  radius: height / 2.6
  color: root.fillColor

  Text {
    id: label
    anchors.centerIn: parent
    text: root.badgeLabel
    textFormat: Text.PlainText
    color: root.textColor
    font.family: Style.font.family
    font.pixelSize: root.fontSize
    font.bold: true
    font.letterSpacing: 0.4
    verticalAlignment: Text.AlignVCenter
  }
}

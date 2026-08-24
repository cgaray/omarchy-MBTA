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
  readonly property color routeColor: root.group && root.group.badge
    ? ("#" + root.group.badge.color) : root.accentColor
  readonly property int hiddenTimeCount: root.group && root.group.times
    ? Math.max(0, root.group.times.length - 3) + Number(root.group.more || 0) : 0

  signal activated()
  signal hoverStateChanged(var group, bool hovered)

  property real spacing: Style.space(8)
  height: Style.space(34)

  readonly property string primaryLabel: root.group && root.group.times
    && root.group.times.length > 0 && root.nowMs > 0
    ? Mbta.countdownLabel(root.group.times[0].ms - root.nowMs) : ""

  readonly property string accessibleText: (root.group && root.group.badge
      ? root.group.badge.label + " " : "")
    + (root.group && root.group.headsign !== "" ? "toward " + root.group.headsign : "Departures")
    + (primaryLabel !== "" ? ", next " + primaryLabel : "")
    + (root.selected ? ", selected" : "")

  Rectangle {
    id: background
    anchors.fill: parent
    anchors.topMargin: 1
    anchors.bottomMargin: 1
    radius: Math.min(6, Style.cornerRadius)
    color: root.selected ? Qt.alpha(root.routeColor, 0.14)
      : (rowArea.containsMouse ? Qt.alpha(root.foreground, 0.065) : "transparent")
    Behavior on color { ColorAnimation { duration: 110 } }
  }

  Rectangle {
    visible: root.selected
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: 2
    height: parent.height - Style.space(10)
    radius: width / 2
    color: root.routeColor
  }

  Row {
    id: contentRow
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(4)
    anchors.rightMargin: Style.space(2)
    spacing: root.spacing

    Item {
      id: badgeSlot
      width: Style.space(34)
      height: root.height

      RouteBadge {
        id: badge
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        badgeLabel: root.group ? root.group.badge.label : ""
        badgeColorHex: root.group ? root.group.badge.color : ""
        badgeTextHex: root.group ? root.group.badge.textColor : ""
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, contentRow.width - badgeSlot.width - timeCluster.width
        - toggleIndicator.width - (statusLabel.visible ? statusLabel.width : 0)
        - root.spacing * (statusLabel.visible ? 4 : 3))
      text: root.group && root.group.headsign !== "" ? root.group.headsign : "Departures"
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    // Live prediction status ("Delayed", "Approaching", …) when the API
    // reports one for the next departure; schedules leave it blank.
    Text {
      id: statusLabel
      readonly property string value: root.group && root.group.times
        && root.group.times.length > 0 ? String(root.group.times[0].status || "") : ""
      visible: value !== ""
      width: Math.min(implicitWidth, Style.space(90))
      text: value
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Qt.alpha(root.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.italic: true
      anchors.verticalCenter: parent.verticalCenter
    }

    Item {
      id: timeCluster
      width: Style.space(128)
      height: root.height

      Rectangle {
        visible: !!root.group && root.group.times && root.group.times.length > 0
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(38)
        height: Style.space(23)
        radius: height / 2
        color: Qt.alpha(root.routeColor, 0.16)
        border.width: 1
        border.color: Qt.alpha(root.routeColor, 0.34)

        Text {
          anchors.centerIn: parent
          text: primaryLabel
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(46)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Repeater {
          model: root.group && root.group.times ? root.group.times.slice(1, 3) : []

          Text {
            required property var modelData
            anchors.verticalCenter: parent.verticalCenter
            text: modelData && root.nowMs > 0
              ? Mbta.countdownLabel(modelData.ms - root.nowMs) : ""
            color: Qt.alpha(root.foreground, 0.62)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Rectangle {
          visible: root.hiddenTimeCount > 0
          width: moreLabel.implicitWidth + Style.space(7)
          height: Style.space(18)
          radius: height / 2
          color: Qt.alpha(root.foreground, 0.10)

          Text {
            id: moreLabel
            anchors.centerIn: parent
            text: "+" + root.hiddenTimeCount
            color: Qt.alpha(root.foreground, 0.58)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }

    Text {
      id: toggleIndicator
      anchors.verticalCenter: parent.verticalCenter
      text: root.selected ? "−" : "›"
      color: Qt.alpha(root.foreground, 0.52)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
  }

  MouseArea {
    id: rowArea
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    hoverEnabled: true
    onEntered: root.hoverStateChanged(root.group, true)
    onExited: root.hoverStateChanged(root.group, false)
    onClicked: root.activated()

    Accessible.role: Accessible.Button
    Accessible.name: root.accessibleText
    Accessible.selected: root.selected
    Accessible.onPressAction: root.activated()
  }
}

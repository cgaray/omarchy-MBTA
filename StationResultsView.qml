import QtQuick
import qs.Commons

Item {
  id: root

  property var results: []
  property int selectedIndex: -1
  property var configuredStopIds: []
  property string emptyText: ""
  property bool showDistances: false

  signal pick(int indexAt)
  signal hoveredRow(int indexAt)

  readonly property real maxViewportHeight: Style.space(330)
  implicitHeight: Math.min(maxViewportHeight, resultsColumn.implicitHeight)
  height: implicitHeight

  onSelectedIndexChanged: scrollToSelected()

  // Keyboard selection must stay visible; matches the column's row+spacing.
  function scrollToSelected() {
    if (selectedIndex < 0) return
    var step = Style.space(24) + 2
    var top = selectedIndex * step
    var bottom = top + step
    if (top < viewport.contentY) viewport.contentY = top
    else if (bottom > viewport.contentY + viewport.height) viewport.contentY = bottom - viewport.height
  }

  Flickable {
    id: viewport
    anchors.fill: parent
    anchors.rightMargin: scrollTrack.visible ? Style.space(8) : 0
    contentWidth: width
    contentHeight: resultsColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: resultsColumn
      width: viewport.width
      spacing: 2

      Text {
        visible: root.emptyText !== ""
        width: parent.width
        text: root.emptyText
        textFormat: Text.PlainText
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.results

        StationResultRow {
          required property int index
          required property var modelData
          at: index
          station: modelData
          selected: index === root.selectedIndex
          picked: root.configuredStopIds.indexOf(modelData.id) >= 0
          distanceText: root.showDistances ? root.formatDistance(modelData.distanceMeters) : ""
          onPick: function(at) { root.pick(at) }
          onHoveredRow: function(at) { root.hoveredRow(at) }
        }
      }
    }
  }

  Rectangle {
    id: scrollTrack
    visible: viewport.contentHeight > viewport.height + 1
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(3)
    radius: width / 2
    color: Qt.alpha(Color.foreground, 0.12)

    Rectangle {
      width: parent.width
      height: Math.max(Style.space(24), parent.height * viewport.height / viewport.contentHeight)
      y: viewport.contentHeight <= viewport.height ? 0
        : (parent.height - height) * viewport.contentY / (viewport.contentHeight - viewport.height)
      radius: width / 2
      color: Color.accent
    }
  }

  function formatDistance(meters) {
    var value = Number(meters)
    if (!isFinite(value) || value < 0) return ""
    if (value < 950) return Math.round(value) + " m"
    return (Math.round(value / 100) / 10) + " km"
  }
}

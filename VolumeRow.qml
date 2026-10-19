import QtQuick
import qs.Commons
import qs.Ui

// Player volume (fork addition): mute button, slider, percentage. Dragging
// changes mpv at once; the value is saved to shell.json a moment after you
// stop, so a drag is not dozens of config writes. ↑/↓ in the Player step it
// by 5 and `m` mutes.
Item {
  id: row

  required property var panel

  width: parent ? parent.width : 0
  height: Style.space(28)

  readonly property int shown: panel.liveVolume

  PanelActionButton {
    id: muteButton
    iconText: row.panel.muted || row.shown === 0 ? "\uf026"
      : (row.shown < 50 ? "\uf027" : "\uf028")
    tooltipText: row.panel.muted ? "Unmute (m)" : "Mute (m)"
    foreground: row.panel.muted ? Color.urgent : row.panel.dim
    hoverColor: Color.accent
    fontFamily: row.panel.fontName
    fontSize: Style.font.bodySmall
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    onClicked: row.panel.toggleMute()
  }

  PanelSlider {
    id: slider
    bar: row.panel.bar
    minimum: 0
    maximum: 130
    step: 5
    integer: true
    value: row.shown
    opacity: row.panel.muted ? 0.4 : 1
    anchors.left: muteButton.right
    anchors.leftMargin: Style.space(6)
    anchors.right: label.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    onMoved: function(value) { row.panel.setVolume(value, false); saveTimer.restart() }
    onReleased: function(value) { row.panel.setVolume(value, true) }
  }

  Text {
    id: label
    textFormat: Text.PlainText
    width: Style.space(40)
    text: row.shown + "%"
    color: row.shown > 100 ? Color.accent : row.panel.fg
    font.family: row.panel.fontName
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
  }

  Timer {
    id: saveTimer
    interval: 600
    onTriggered: row.panel.setVolume(row.panel.liveVolume, true)
  }
}

import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The per-row download control (fork addition): download, cancel, delete the
// local copy, or retry, depending on where the episode stands. The state
// text beside it is drawn by EpisodeRow from the same item.
PanelActionButton {
  id: button

  required property var panel
  required property var episode

  readonly property var item: panel.offline.itemOf(episode.id)
  readonly property string dlState: panel.offline.stateOf(episode.id)

  iconText: Model.downloadIcon(dlState)
  tooltipText: Model.downloadTooltip(dlState, item)
  foreground: dlState === "done" || dlState === "downloading" ? Color.accent
    : (dlState === "failed" ? Color.urgent : panel.dim)
  hoverColor: Color.accent
  fontFamily: panel.fontName
  fontSize: Style.font.bodySmall
  onClicked: panel.offline.toggle(episode)
}

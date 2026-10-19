import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Feed (fork addition): everything that came out lately across all your
// shows, played, queued or downloaded straight from the list. Unlike the
// inbox nothing leaves it when you act on it — it is a timeline, not a
// to-do list.
Column {
  id: view

  required property var panel

  readonly property var feed: panel.feed

  spacing: Style.space(2)

  Item {
    width: parent.width
    height: Style.space(24)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: view.feed.total + " episode" + (view.feed.total === 1 ? "" : "s")
        + " in the last " + (view.feed.days === 1 ? "day" : view.feed.days + " days")
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      PanelActionButton {
        iconText: "−"
        tooltipText: "Fewer days"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        onClicked: view.feed.stepDays(-1)
      }
      PanelActionButton {
        iconText: "+"
        tooltipText: "More days"
        foreground: view.panel.dim
        hoverColor: Color.accent
        fontFamily: view.panel.fontName
        fontSize: Style.font.bodySmall
        onClicked: view.feed.stepDays(1)
      }
    }
  }

  Repeater {
    model: view.feed.episodes

    EpisodeRow {
      required property int index
      required property var modelData

      panel: view.panel
      episode: modelData
      selected: view.panel.view === "feed" && view.panel.cursor === index
      trailingIcon: modelData.queued ? "" : ""
      trailingTooltip: modelData.queued ? "In the queue — click to remove" : "Add to queue (q)"

      onActivated: {
        view.panel.cursor = index
        view.panel.playEpisode(modelData, {})
      }
      onSecondary: {
        view.panel.cursor = index
        view.panel.enqueueEpisode(modelData, false)
        view.panel.note("queued · " + modelData.title)
      }
      onTrailingClicked: {
        if (modelData.queued) view.panel.removeFromQueue(modelData)
        else {
          view.panel.enqueueEpisode(modelData, false)
          view.panel.note("queued · " + modelData.title)
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: view.feed.loaded && view.feed.episodes.length === 0
    width: parent.width
    topPadding: Style.space(18)
    bottomPadding: Style.space(14)
    text: view.panel.shows.length === 0
      ? "no subscriptions yet — open Shows to add some"
      : "nothing new in the last " + view.feed.days + " days — press + to look further back"
    color: view.panel.dim
    font.family: view.panel.fontName
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
  }
}

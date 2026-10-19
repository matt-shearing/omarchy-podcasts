import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The DOWNLOADS block on the ⚙ page (fork addition): how many run at once,
// the size cap, how long played episodes are kept, disk used, delete all.
Column {
  id: view

  required property var panel

  readonly property var offline: panel.offline

  spacing: Style.space(8)

  PanelSectionHeader {
    text: "DOWNLOADS"
    foreground: view.panel.fg
    fontFamily: view.panel.fontName
  }

  Repeater {
    model: [
      { label: "Downloads at once", key: "downloadParallel", step: 1, min: 1, max: 6 },
      { label: "Largest episode", key: "downloadMaxMB", step: 256, min: 256, max: 8192 },
      { label: "Delete played after", key: "downloadCleanupDays", step: 1, min: 0, max: 365 }
    ]

    Item {
      id: stepper
      required property var modelData

      readonly property int value: modelData.key === "downloadParallel" ? view.offline.parallel
        : (modelData.key === "downloadMaxMB" ? view.offline.maxMb : view.offline.cleanupDays)

      width: parent.width
      height: Style.space(30)

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: stepper.modelData.label
        color: view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.body
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        PanelActionButton {
          iconText: "−"
          foreground: view.panel.dim
          hoverColor: Color.accent
          fontFamily: view.panel.fontName
          fontSize: Style.font.bodySmall
          onClicked: view.panel.setDownloadSetting(stepper.modelData,
            stepper.value - stepper.modelData.step)
        }
        Text {
          textFormat: Text.PlainText
          width: Style.space(64)
          text: stepper.modelData.key === "downloadMaxMB"
            ? Model.bytesLabel(stepper.value * 1024 * 1024)
            : (stepper.modelData.key === "downloadCleanupDays"
              ? (stepper.value === 0 ? "never" : stepper.value + (stepper.value === 1 ? " day" : " days"))
              : String(stepper.value))
          color: view.panel.fg
          font.family: view.panel.fontName
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
        }
        PanelActionButton {
          iconText: "+"
          foreground: view.panel.dim
          hoverColor: Color.accent
          fontFamily: view.panel.fontName
          fontSize: Style.font.bodySmall
          onClicked: view.panel.setDownloadSetting(stepper.modelData,
            stepper.value + stepper.modelData.step)
        }
      }
    }
  }

  Item {
    width: parent.width
    height: Style.space(30)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: clearButton.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.bytesLabel(view.offline.usedBytes) + " used"
        + (view.offline.pending > 0 ? " · " + view.offline.pending + " downloading" : "")
      color: view.panel.dim
      font.family: view.panel.fontName
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Rectangle {
      id: clearButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: clearText.implicitWidth + Style.space(16)
      height: clearText.implicitHeight + Style.space(8)
      radius: Style.cornerRadius
      color: clearArea.containsMouse
        ? Style.hoverFillFor(view.panel.fg, Color.urgent) : "transparent"
      border.width: 1
      border.color: view.panel.faint

      Text {
        id: clearText
        anchors.centerIn: parent
        text: view.confirming ? "Click again to delete all" : "Delete all downloads"
        color: view.confirming ? Color.urgent : view.panel.fg
        font.family: view.panel.fontName
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: clearArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          if (view.confirming) {
            view.confirming = false
            view.offline.clearAll()
          } else {
            view.confirming = true
            confirmTimer.restart()
          }
        }
      }
    }
  }

  property bool confirming: false

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: view.confirming = false
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: "saved in ~/.local/share/omarchy-podcasts/downloads — a downloaded episode "
      + "plays from disk, so it works with no connection"
    color: view.panel.dim
    font.family: view.panel.fontName
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}

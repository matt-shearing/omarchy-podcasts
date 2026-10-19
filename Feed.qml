import QtQuick
import Quickshell.Io
import "Model.js" as Model

// The Feed view's data (fork addition): every episode from every show over
// the last `days` days, newest first. Reloaded whenever the library reloads
// (after any action and every feed check) and when the window changes.
Item {
  id: feed

  required property var panel

  visible: false

  readonly property int days: {
    var value = parseInt(panel.setting("feedDays", 14), 10)
    return isNaN(value) ? 14 : Math.max(1, Math.min(365, value))
  }

  property var episodes: []
  property int total: 0
  property bool loaded: false
  property bool again: false

  function reload() {
    if (proc.running) { again = true; return }
    proc.command = Model.feedCommand(panel.scriptDir, days)
    proc.running = true
  }

  function stepDays(delta) {
    var steps = [1, 3, 7, 14, 30, 60, 90, 180, 365]
    var at = 0
    for (var i = 0; i < steps.length; i++) if (steps[i] <= days) at = i
    at = Math.max(0, Math.min(steps.length - 1, at + delta))
    panel.persistSettings({ feedDays: steps[at] })
  }

  onDaysChanged: reload()

  Process {
    id: proc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        if (reply.ok) {
          feed.episodes = reply.episodes || []
          feed.total = reply.total || 0
          feed.loaded = true
          if (feed.panel.view === "feed") feed.panel.clampCursor()
        }
      }
    }
    onExited: if (feed.again) { feed.again = false; Qt.callLater(feed.reload) }
  }

  Connections {
    target: feed.panel
    function onLibraryChanged() { feed.reload() }
  }

  Component.onCompleted: reload()
}

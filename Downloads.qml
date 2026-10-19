import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Offline downloads (fork addition). The panel holds one of these; it owns
// the download processes and the latest status, and the panel calls into it
// at three places: playback picks its source here, a finished feed refresh
// kicks the worker, and the `d` key / row button toggle a download.
//
// The worker (`download-run`) is one long-lived helper process that downloads
// whatever is queued, at most `parallel` at once, and exits when the queue is
// empty. It also does the startup work — resuming partial files a killed
// shell left behind, and deleting played episodes past the retention window —
// so it is started once when the panel loads even with nothing queued.
Item {
  id: offline

  required property var panel

  visible: false

  readonly property int parallel: Math.max(1, Math.min(6,
    parseInt(panel.setting("downloadParallel", 2), 10) || 2))
  readonly property int maxMb: Math.max(50, Math.min(16384,
    parseInt(panel.setting("downloadMaxMB", 1024), 10) || 1024))
  readonly property int cleanupDays: {
    var days = parseInt(panel.setting("downloadCleanupDays", 7), 10)
    return isNaN(days) ? 7 : Math.max(0, Math.min(3650, days))
  }

  property var items: ({})
  property var showPrefs: ({})
  property real usedBytes: 0
  property int pending: 0
  readonly property bool busy: workerProc.running || pending > 0

  // The episode whose local file mpv was last asked to play, so a file that
  // will not open falls back to streaming instead of failing the episode.
  property string localTry: ""

  function stateOf(episodeId) { return Model.downloadState(items, episodeId) }
  function itemOf(episodeId) { return items[episodeId] || null }

  function sourceFor(episode) {
    var source = Model.playbackSource(items, episode)
    localTry = source !== "" && episode && source !== episode.url ? episode.id : ""
    return source
  }

  // Called from the player's end-file error branch. True when it has
  // switched to streaming, in which case the caller should not report an
  // error.
  function streamInstead(episode) {
    if (!episode || localTry !== episode.id || !episode.url) return false
    localTry = ""
    panel.sendLoad(episode.url)
    panel.note("local copy would not play; streaming instead")
    status()
    return true
  }

  function autoFor(show) {
    if (!show) return false
    var pref = showPrefs[show.id]
    if (pref && typeof pref.auto === "boolean") return pref.auto
    return show.mode === "auto"
  }

  function setAuto(show, on) {
    if (!show) return
    actionProc.enqueue(Model.downloadShowCommand(panel.scriptDir, show.id, on ? "on" : "off"))
  }

  function toggle(episode) {
    if (!episode || !episode.id) return
    var state = stateOf(episode.id)
    if (state === "none" || state === "failed") {
      actionProc.enqueue(Model.downloadAddCommand(panel.scriptDir, episode.id), true)
      panel.note("downloading · " + episode.title)
    } else {
      actionProc.enqueue(Model.downloadRemoveCommand(panel.scriptDir, episode.id))
      panel.note((state === "done" ? "deleted download · " : "cancelled · ") + episode.title)
    }
  }

  function clearAll() {
    actionProc.enqueue(Model.downloadClearCommand(panel.scriptDir))
    panel.note("deleted all downloads")
  }

  function kick() {
    if (workerProc.running) return
    workerProc.command = Model.downloadRunCommand(panel.scriptDir, parallel, maxMb, cleanupDays)
    workerProc.running = true
    lastKick = Date.now()
  }

  function status() {
    if (!statusProc.running) statusProc.running = true
  }

  // Mutations, one at a time, each followed by a status read. `start` means
  // the worker should pick the change up.
  Process {
    id: actionProc
    property var pending: []
    property bool startAfter: false

    function enqueue(command, start) {
      pending.push({ command: command, start: start === true })
      pump()
    }

    function pump() {
      if (running || pending.length === 0) return
      var next = pending.shift()
      startAfter = next.start
      command = next.command
      running = true
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        if (!reply.ok) offline.panel.note(reply.error || "that did not work")
        else offline.apply(reply)
        if (actionProc.startAfter) offline.kick()
      }
    }
    onExited: Qt.callLater(actionProc.pump)
  }

  Process {
    id: statusProc
    command: Model.downloadStatusCommand(offline.panel.scriptDir)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        if (reply.ok) offline.apply(reply)
      }
    }
  }

  Process {
    id: workerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        if (!reply.ok) offline.panel.note(reply.error || "downloads stopped")
        else if (reply.failed > 0) offline.panel.note(reply.failed + " download"
          + (reply.failed === 1 ? "" : "s") + " failed")
      }
    }
    onExited: offline.status()
  }

  function apply(reply) {
    if (reply.items) items = reply.items
    if (reply.shows) showPrefs = reply.shows
    usedBytes = reply.usedBytes || 0
    pending = reply.pending || 0
    // Work queued while the worker was winding down, or by a feed refresh's
    // auto-download. Throttled, so a worker that keeps dying is not
    // restarted every second.
    if (pending > 0 && !workerProc.running && reply.worker === false
        && Date.now() - lastKick > 30000) kick()
  }

  property real lastKick: 0

  // Progress while anything is moving; quiet otherwise.
  Timer {
    id: statusTimer
    interval: 1000
    repeat: true
    running: offline.busy
    onTriggered: offline.status()
  }

  // Every library reload — after any action, every feed check — re-reads
  // download state too, so a file finished by another worker (a second
  // shell, the command line) is played locally without waiting.
  Connections {
    target: offline.panel
    function onLibraryChanged() { offline.status() }
  }

  Component.onCompleted: {
    status()
    // Startup: resume partials, apply retention. Exits at once if idle.
    Qt.callLater(kick)
  }

  Component.onDestruction: {
    if (workerProc.running) workerProc.running = false
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// New Vegas Radio: Fallout radio stations from fallout.fm, played with mpv.
// Left-click plays or stops, right-click moves to the next station, scrolling
// changes the volume. The tooltip shows the station and the song on air, which
// mpv reports over its IPC socket as it changes, so nothing polls. The station
// and volume are remembered in ~/.local/state/omarchy/nv-radio.json.
BarWidget {
  id: root
  moduleName: "io.github.spconley98.nv-radio"

  readonly property var stations: [
    { name: "Radio New Vegas", url: "http://fallout.fm:8000/falloutfm3.ogg" },
    { name: "Galaxy News Radio", url: "http://fallout.fm:8000/falloutfm2.ogg" },
    { name: "Diamond City Radio", url: "http://fallout.fm:8000/falloutfm6.ogg" },
    { name: "Appalachia Classical", url: "http://fallout.fm:8000/falloutfm9.ogg" }
  ]

  property int station: 0
  property int volume: 60
  property string nowPlaying: ""
  property bool buffering: false
  readonly property bool playing: player.running
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-nv-radio.sock"

  // ------------------------------------------------------------ playback
  Process {
    id: player
    command: ["mpv", "--no-video", "--force-window=no", "--really-quiet", "--no-terminal",
      "--cache=yes", "--volume=" + root.volume, "--title=New Vegas Radio",
      "--input-ipc-server=" + root.socketPath, root.stations[root.station].url]
    onRunningChanged: {
      if (running) {
        root.buffering = true
        connectRetry.restart()
      } else {
        ipc.connected = false
        connectRetry.stop()
        root.nowPlaying = ""
        root.buffering = false
      }
    }
  }

  function toggle() {
    player.running = !player.running
  }

  function nextStation() {
    root.station = (root.station + 1) % root.stations.length
    root.nowPlaying = ""
    root.saveState()
    if (player.running) {
      root.buffering = true
      root.send(["loadfile", root.stations[root.station].url, "replace"])
    }
  }

  function changeVolume(step) {
    root.volume = Math.max(0, Math.min(100, root.volume + step))
    root.saveState()
    if (player.running) root.send(["set_property", "volume", root.volume])
  }

  // -------------------------------------------------------- mpv IPC socket
  function send(command) {
    if (ipc.connected) {
      ipc.write(JSON.stringify({ command: command }) + "\n")
      ipc.flush()
    }
  }

  Socket {
    id: ipc
    path: root.socketPath
    onConnectedChanged: {
      if (connected) {
        connectRetry.stop()
        root.send(["observe_property", 1, "media-title"])
        root.send(["observe_property", 2, "core-idle"])
      }
    }
    parser: SplitParser {
      onRead: function(line) {
        var msg
        try { msg = JSON.parse(line) } catch (e) { return }
        if (msg.event !== "property-change") return
        if (msg.name === "media-title") {
          var title = String(msg.data || "")
          // Before the stream sends a song title, mpv reports the file name.
          root.nowPlaying = /falloutfm\d+\.ogg$/.test(title) ? "" : title
        } else if (msg.name === "core-idle") {
          root.buffering = msg.data === true
        }
      }
    }
  }

  // mpv makes its socket a moment after it starts; try a few times until it's there.
  Timer {
    id: connectRetry
    interval: 300
    repeat: true
    property int tries: 0
    onRunningChanged: if (running) tries = 0
    onTriggered: {
      if (ipc.connected || ++tries > 30) { stop(); return }
      ipc.connected = true
    }
  }

  // ---------------------------------------------------------- remembered
  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/nv-radio.json"
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        if (s.station >= 0 && s.station < root.stations.length) root.station = s.station
        if (s.volume >= 0 && s.volume <= 100) root.volume = s.volume
      } catch (e) {}
    }
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ station: root.station, volume: root.volume }))
  }

  // ----------------------------------------------------------------- UI
  readonly property string tooltip: {
    var s = root.stations[root.station].name
    var line = root.playing
      ? (root.buffering && !root.nowPlaying ? "Tuning in…" : (root.nowPlaying || "On air"))
      : "Off"
    return s + " · " + line + "\nVolume " + root.volume + "%"
      + "\nClick: " + (root.playing ? "stop" : "play") + " · Right-click: next station · Scroll: volume"
  }

  implicitWidth: vertical ? barSize : button.implicitWidth
  implicitHeight: vertical ? button.implicitHeight : barSize

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐹"
    slotSize: Style.bar.iconSlot
    opacity: root.playing ? 1.0 : 0.55
    tooltipText: root.tooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.nextStation()
      else if (b === Qt.LeftButton) root.toggle()
    }
    onWheelMoved: function(delta) { root.changeVolume(delta > 0 ? 5 : -5) }
  }

  Component.onDestruction: player.running = false
}

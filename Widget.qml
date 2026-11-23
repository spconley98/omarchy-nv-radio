import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// New Vegas Radio: Fallout radio stations from fallout.fm, played with mpv.
//
// Left-click opens a green-phosphor wrist-terminal tuner listing every station.
// Middle-click plays or stops, right-click moves to the next station, and
// scrolling changes the volume, all without opening the tuner. The song on air
// comes from mpv over its IPC socket as it changes, so nothing polls. The
// station and volume are remembered in ~/.local/state/omarchy/nv-radio.json.
Panel {
  id: root
  moduleName: "io.github.spconley98.nv-radio"
  ipcTarget: "io.github.spconley98.nv-radio"

  // Every stream fallout.fm runs. Talk-only stations from the games (Enclave
  // Radio, Freedom Radio, Black Mountain) have no stream anywhere, so they
  // can't be here.
  readonly property var stations: [
    { name: "Radio New Vegas", game: "FALLOUT: NEW VEGAS", tag: "NV", url: "https://fallout.fm:8444/falloutfm3.ogg" },
    { name: "Galaxy News Radio", game: "FALLOUT 3", tag: "FO3", url: "https://fallout.fm:8444/falloutfm2.ogg" },
    { name: "Diamond City Radio", game: "FALLOUT 4", tag: "FO4", url: "https://fallout.fm:8444/falloutfm6.ogg" },
    { name: "Classical Radio", game: "FALLOUT 4", tag: "FO4", url: "https://fallout.fm:8444/falloutfm7.ogg" },
    { name: "More Where That Came From", game: "FALLOUT 4 · EXPANDED DCR", tag: "FO4", url: "https://fallout.fm:8444/falloutfm8.ogg" },
    { name: "Appalachia Radio", game: "FALLOUT 76", tag: "F76", url: "https://fallout.fm:8444/falloutfm10.ogg" },
    { name: "Classical Radio", game: "FALLOUT 76", tag: "F76", url: "https://fallout.fm:8444/falloutfm9.ogg" },
    { name: "Fallout 2 Soundtrack", game: "FALLOUT 2", tag: "FO2", url: "https://fallout.fm:8444/falloutfm4.ogg" },
    { name: "Fallout Soundtrack", game: "FALLOUT", tag: "FO1", url: "https://fallout.fm:8444/falloutfm5.ogg" },
    { name: "Fallout.FM Mix", game: "ALL GAMES", tag: "MIX", url: "https://fallout.fm:8444/falloutfm1.ogg" }
  ]

  property int station: 0
  property int cursor: 0
  property int volume: 60
  property string nowPlaying: ""
  property bool buffering: false
  readonly property bool playing: player.running
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-nv-radio.sock"

  // Phosphor palette: fixed, not themed, because the look is the point.
  readonly property color phosphor: "#41ff8c"
  readonly property color phosphorDim: "#1f9a52"
  readonly property color phosphorFaint: "#0f4a28"
  readonly property color screen: "#06140b"
  readonly property string mono: "monospace"

  onOpenedChanged: if (opened) cursor = station

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

  function togglePlay() {
    player.running = !player.running
  }

  function tune(index) {
    if (index === root.station) {
      if (!player.running) player.running = true
      return
    }
    root.station = index
    root.cursor = index
    root.nowPlaying = ""
    root.saveState()
    if (player.running) {
      root.buffering = true
      root.send(["loadfile", root.stations[index].url, "replace"])
    } else {
      player.running = true
    }
  }

  function nextStation() {
    var next = (root.station + 1) % root.stations.length
    if (player.running) {
      root.tune(next)
    } else {
      root.station = next
      root.cursor = next
      root.saveState()
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
          root.nowPlaying = /falloutfm\d+\.ogg$/.test(title) || title === "None" ? "" : title
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
        root.cursor = root.station
      } catch (e) {}
    }
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ station: root.station, volume: root.volume }))
  }

  // ----------------------------------------------------------------- bar
  readonly property string statusLine: root.playing
    ? (root.buffering && !root.nowPlaying ? "Tuning in…" : (root.nowPlaying || "On air"))
    : "Off"

  readonly property string tooltip: root.stations[root.station].name + " · " + root.statusLine
    + "\nVolume " + root.volume + "%"
    + "\nClick: tuner · Middle-click: " + (root.playing ? "stop" : "play")
    + " · Right-click: next station · Scroll: volume"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐹"
    slotSize: Style.bar.iconSlot
    opacity: root.playing ? 1.0 : 0.55
    tooltipText: root.opened ? "" : root.tooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.nextStation()
      else if (b === Qt.MiddleButton) root.togglePlay()
      else root.toggle()
    }
    onWheelMoved: function(delta) { root.changeVolume(delta > 0 ? 5 : -5) }
  }

  // --------------------------------------------------------------- tuner
  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    padding: 0
    focusTarget: popup.loadedContent
    contentWidth: Style.space(620)
    contentHeight: Style.space(430)

    content: PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.cursor = (root.cursor + dy + root.stations.length) % root.stations.length
        if (dx !== 0) root.changeVolume(dx * 5)
      }
      // Enter or Space: tune to the highlighted station, or stop it if it's the one playing.
      onActivateRequested: {
        if (root.cursor === root.station && root.playing) root.togglePlay()
        else root.tune(root.cursor)
      }

      Rectangle {
        id: crt
        anchors.fill: parent
        color: root.screen
        radius: Style.space(10)
        clip: true

        // Header: title, then a rule with section ticks.
        Text {
          id: title
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.leftMargin: Style.space(22)
          anchors.topMargin: Style.space(16)
          text: "WASTELAND RADIO"
          color: root.phosphor
          font.family: root.mono
          font.pixelSize: Style.space(20)
          font.bold: true
          font.letterSpacing: 2
        }

        Text {
          anchors.right: parent.right
          anchors.baseline: title.baseline
          anchors.rightMargin: Style.space(22)
          text: "VOL " + root.volume + "%   " + (root.playing ? "■ ON AIR" : "□ OFF")
          color: root.phosphor
          font.family: root.mono
          font.pixelSize: Style.space(14)
        }

        Rectangle {
          id: rule
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: title.bottom
          anchors.leftMargin: Style.space(16)
          anchors.rightMargin: Style.space(16)
          anchors.topMargin: Style.space(8)
          height: 2
          color: root.phosphor
        }

        // Station list.
        Column {
          id: list
          anchors.left: parent.left
          anchors.top: rule.bottom
          anchors.leftMargin: Style.space(16)
          anchors.topMargin: Style.space(10)
          width: Style.space(300)
          spacing: Style.space(2)

          Repeater {
            model: root.stations

            Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool current: index === root.station
              readonly property bool focused: index === root.cursor || rowMouse.containsMouse
              width: list.width
              height: Style.space(30)
              color: focused ? root.phosphor : "transparent"

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(64)
                elide: Text.ElideRight
                text: (row.current && root.playing ? "▶ " : "  ") + row.modelData.name
                color: row.focused ? root.screen : root.phosphor
                font.family: root.mono
                font.pixelSize: Style.space(15)
                font.bold: row.current
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.tag
                color: row.focused ? root.screen : root.phosphorDim
                font.family: root.mono
                font.pixelSize: Style.space(12)
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.cursor = row.index
                onClicked: {
                  if (row.current && root.playing) root.togglePlay()
                  else root.tune(row.index)
                }
              }
            }
          }
        }

        // Right side: the signal scope and what's on air.
        Item {
          id: side
          anchors.left: list.right
          anchors.right: parent.right
          anchors.top: rule.bottom
          anchors.bottom: footer.top
          anchors.leftMargin: Style.space(16)
          anchors.rightMargin: Style.space(16)
          anchors.topMargin: Style.space(12)
          anchors.bottomMargin: Style.space(10)

          Rectangle {
            id: scopeFrame
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Style.space(190)
            color: "transparent"
            border.color: root.phosphorDim
            border.width: 1

            // Grid lines.
            Repeater {
              model: 7
              Rectangle {
                required property int index
                x: (index + 1) * scopeFrame.width / 8
                width: 1
                height: scopeFrame.height
                color: root.phosphorFaint
              }
            }
            Repeater {
              model: 3
              Rectangle {
                required property int index
                y: (index + 1) * scopeFrame.height / 4
                height: 1
                width: scopeFrame.width
                color: root.phosphorFaint
              }
            }

            Canvas {
              id: scope
              anchors.fill: parent
              property real phase: 0
              onPhaseChanged: requestPaint()
              Component.onCompleted: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.strokeStyle = root.phosphor
                ctx.lineWidth = 2
                ctx.shadowColor = root.phosphor
                ctx.shadowBlur = 6
                ctx.beginPath()
                var mid = height / 2
                var live = root.playing && !root.buffering
                var amp = live ? height * 0.32 * (0.35 + root.volume / 150) : 0
                for (var x = 0; x <= width; x += 2) {
                  var t = x / width
                  var y = mid
                    + amp * 0.6 * Math.sin(t * 6.3 * 3 + phase)
                    + amp * 0.3 * Math.sin(t * 6.3 * 7 - phase * 1.7)
                    + amp * 0.15 * Math.sin(t * 6.3 * 13 + phase * 2.3)
                  if (x === 0) ctx.moveTo(x, y)
                  else ctx.lineTo(x, y)
                }
                ctx.stroke()
              }
            }

            // Runs only while the tuner is open and the radio is playing.
            NumberAnimation {
              target: scope
              property: "phase"
              from: 0
              to: Math.PI * 2
              duration: 1600
              loops: Animation.Infinite
              running: root.opened && root.playing && !root.buffering
            }
          }

          Text {
            id: stationName
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: scopeFrame.bottom
            anchors.topMargin: Style.space(14)
            elide: Text.ElideRight
            text: root.stations[root.station].name.toUpperCase()
            color: root.phosphor
            font.family: root.mono
            font.pixelSize: Style.space(15)
            font.bold: true
          }

          Text {
            id: gameName
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: stationName.bottom
            anchors.topMargin: Style.space(2)
            elide: Text.ElideRight
            text: root.stations[root.station].game
            color: root.phosphorDim
            font.family: root.mono
            font.pixelSize: Style.space(12)
          }

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: gameName.bottom
            anchors.topMargin: Style.space(10)
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.playing
              ? (root.buffering && !root.nowPlaying ? "TUNING IN…" : "♪ " + (root.nowPlaying || "ON AIR"))
              : "RADIO OFF"
            color: root.phosphor
            font.family: root.mono
            font.pixelSize: Style.space(14)
          }
        }

        // Footer: key hints.
        Rectangle {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(16)
          anchors.rightMargin: Style.space(16)
          anchors.bottomMargin: Style.space(12)
          height: Style.space(26)
          color: root.phosphorFaint

          Text {
            anchors.centerIn: parent
            text: "↑↓ SELECT   ⏎ PLAY/STOP   ←→ VOLUME   ESC CLOSE"
            color: root.phosphor
            font.family: root.mono
            font.pixelSize: Style.space(12)
          }
        }

        // CRT scanlines over everything; they don't take clicks.
        Column {
          anchors.fill: parent
          enabled: false
          Repeater {
            model: Math.ceil(crt.height / 3)
            Rectangle {
              width: crt.width
              height: 3
              color: "transparent"
              Rectangle {
                width: parent.width
                height: 1
                color: "#000000"
                opacity: 0.28
              }
            }
          }
        }

        // Soft glow at the edges of the glass.
        Rectangle {
          anchors.fill: parent
          radius: crt.radius
          color: "transparent"
          border.color: root.phosphor
          border.width: 1
          opacity: 0.35
        }
      }
    }
  }

  Component.onDestruction: player.running = false
}

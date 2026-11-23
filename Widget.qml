import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// New Vegas Radio: Fallout radio stations from fallout.fm, played with mpv.
//
// Left-click opens a phosphor-screen tuner listing every station. Middle-click
// plays or stops, right-click moves to the next station, and scrolling changes
// the volume, all without opening the tuner. The song on air comes from mpv
// over its IPC socket as it changes, so nothing polls. mpv's MPRIS script, when
// installed, puts the radio on the media keys. The station and volume are
// remembered in ~/.local/state/omarchy/nv-radio.json.
Panel {
  id: root
  moduleName: "io.github.spconley98.nv-radio"
  ipcTarget: "io.github.spconley98.nv-radio"

  // Every stream fallout.fm runs. Talk-only stations from the games (Enclave
  // Radio, Freedom Radio, Black Mountain) have no stream anywhere, so they
  // can't be here. `key` matches the startStation setting's options.
  readonly property var stations: [
    { key: "Radio New Vegas", name: "Radio New Vegas", game: "FALLOUT: NEW VEGAS", tag: "NV", url: "https://fallout.fm:8444/falloutfm3.ogg" },
    { key: "Galaxy News Radio", name: "Galaxy News Radio", game: "FALLOUT 3", tag: "FO3", url: "https://fallout.fm:8444/falloutfm2.ogg" },
    { key: "Diamond City Radio", name: "Diamond City Radio", game: "FALLOUT 4", tag: "FO4", url: "https://fallout.fm:8444/falloutfm6.ogg" },
    { key: "Classical Radio (Fallout 4)", name: "Classical Radio", game: "FALLOUT 4", tag: "FO4", url: "https://fallout.fm:8444/falloutfm7.ogg" },
    { key: "More Where That Came From", name: "More Where That Came From", game: "FALLOUT 4 · EXPANDED DCR", tag: "FO4", url: "https://fallout.fm:8444/falloutfm8.ogg" },
    { key: "Appalachia Radio", name: "Appalachia Radio", game: "FALLOUT 76", tag: "F76", url: "https://fallout.fm:8444/falloutfm10.ogg" },
    { key: "Classical Radio (Fallout 76)", name: "Classical Radio", game: "FALLOUT 76", tag: "F76", url: "https://fallout.fm:8444/falloutfm9.ogg" },
    { key: "Fallout 2 Soundtrack", name: "Fallout 2 Soundtrack", game: "FALLOUT 2", tag: "FO2", url: "https://fallout.fm:8444/falloutfm4.ogg" },
    { key: "Fallout Soundtrack", name: "Fallout Soundtrack", game: "FALLOUT", tag: "FO1", url: "https://fallout.fm:8444/falloutfm5.ogg" },
    { key: "Fallout.FM Mix", name: "Fallout.FM Mix", game: "ALL GAMES", tag: "MIX", url: "https://fallout.fm:8444/falloutfm1.ogg" }
  ]

  property int station: 0
  property int cursor: 0
  property int volume: 60
  property string nowPlaying: ""
  property bool buffering: false
  property var history: []
  // What the user asked for, as opposed to whether mpv happens to be running:
  // a stream that drops keeps this true, and the radio retries until it's back.
  property bool wantPlaying: false
  property bool noSignal: false
  property int retries: 0
  property bool started: false
  readonly property bool playing: wantPlaying
  readonly property bool live: player.running && !buffering && !noSignal
  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-nv-radio.sock"

  // ---------------------------------------------------------- settings
  readonly property var palettes: ({
    green: { hi: "#41ff8c", mid: "#1f9a52", lo: "#0f4a28", bg: "#06140b" },
    amber: { hi: "#ffb642", mid: "#a8732a", lo: "#4a3210", bg: "#140d04" },
    blue: { hi: "#5cc8ff", mid: "#2f7aa6", lo: "#123448", bg: "#04101a" },
    white: { hi: "#e8f0f0", mid: "#8a9696", lo: "#323a3a", bg: "#0a0c0c" }
  })
  readonly property var screenColors: palettes[root.setting("phosphor", "green")] || palettes.green
  readonly property color phosphor: screenColors.hi
  readonly property color phosphorDim: screenColors.mid
  readonly property color phosphorFaint: screenColors.lo
  readonly property color screen: screenColors.bg
  readonly property string mono: "monospace"
  readonly property bool tuningStatic: root.setting("tuningStatic", true) === true

  onOpenedChanged: if (opened) cursor = station

  // ------------------------------------------------------------ playback
  Process {
    id: player
    command: ["mpv", "--no-video", "--force-window=no", "--really-quiet", "--no-terminal",
      "--cache=yes", "--network-timeout=10", "--volume=" + root.volume,
      "--title=New Vegas Radio", "--input-ipc-server=" + root.socketPath,
      root.stations[root.station].url]
    onRunningChanged: {
      if (running) {
        root.buffering = true
        connectRetry.restart()
      } else {
        ipc.connected = false
        connectRetry.stop()
        stallTimer.stop()
        root.nowPlaying = ""
        root.buffering = false
        // mpv quit on its own while the radio should be on: the stream is
        // down or the network went away. Retry, backing off.
        if (root.wantPlaying) {
          root.noSignal = true
          retryTimer.interval = [3000, 10000, 30000][Math.min(root.retries, 2)]
          root.retries++
          retryTimer.restart()
        }
      }
    }
  }

  Timer {
    id: retryTimer
    onTriggered: if (root.wantPlaying && !player.running) player.running = true
  }

  // A stream that stalls without mpv quitting (often after waking from sleep)
  // gets restarted, which the exit handler above turns into a retry.
  Timer {
    id: stallTimer
    interval: 20000
    onTriggered: if (root.buffering && player.running) player.running = false
  }

  onBufferingChanged: {
    if (buffering && player.running) {
      stallTimer.restart()
    } else {
      stallTimer.stop()
      if (!buffering && player.running) {
        root.noSignal = false
        root.retries = 0
      }
    }
  }

  // A short burst of radio static while changing stations: generated noise.
  Process {
    id: staticFx
    command: ["mpv", "--no-video", "--really-quiet", "--no-terminal", "--no-config",
      "--volume=" + Math.round(root.volume * 0.5),
      "av://lavfi:anoisesrc=d=0.45:c=pink:a=0.35,afade=t=out:st=0.25:d=0.2"]
  }

  function crackle() {
    if (!root.tuningStatic || root.volume === 0) return
    staticFx.running = false
    staticFx.running = true
  }

  function play() {
    root.wantPlaying = true
    root.noSignal = false
    root.retries = 0
    retryTimer.stop()
    root.crackle()
    player.running = true
  }

  function stop() {
    root.wantPlaying = false
    root.noSignal = false
    retryTimer.stop()
    player.running = false
  }

  function togglePlay() {
    if (root.wantPlaying) root.stop()
    else root.play()
  }

  function tune(index) {
    if (index === root.station) {
      if (!root.wantPlaying) root.play()
      return
    }
    root.station = index
    root.cursor = index
    root.nowPlaying = ""
    root.saveState()
    if (!root.wantPlaying) {
      root.play()
    } else if (player.running && ipc.connected) {
      root.crackle()
      root.buffering = true
      root.send(["loadfile", root.stations[index].url, "replace"])
    } else {
      // Mid-retry: start over on the new station now.
      player.running = false
      root.play()
    }
  }

  function nextStation() {
    var next = (root.station + 1) % root.stations.length
    if (root.wantPlaying) {
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

  function remember(title) {
    if (title === "" || (root.history.length && root.history[0].title === title)) return
    var list = [{ title: title, tag: root.stations[root.station].tag }].concat(root.history)
    root.history = list.slice(0, 4)
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
          root.remember(root.nowPlaying)
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
      root.startUp()
    }
    onLoadFailed: root.startUp()
  }

  // Applies the start-up settings once, after the remembered state is in.
  function startUp() {
    if (root.started) return
    root.started = true
    var pick = root.setting("startStation", "Last played")
    for (var i = 0; i < root.stations.length; i++)
      if (root.stations[i].key === pick) root.station = i
    if (root.setting("rememberVolume", true) !== true)
      root.volume = Math.max(0, Math.min(100, root.setting("startVolume", 60)))
    root.cursor = root.station
    if (root.setting("autoplay", false) === true) root.play()
  }

  function saveState() {
    stateFile.setText(JSON.stringify({ station: root.station, volume: root.volume }))
  }

  // ----------------------------------------------------------------- bar
  readonly property string statusLine: !root.wantPlaying ? "Off"
    : root.noSignal ? "No signal, retrying"
    : root.buffering && !root.nowPlaying ? "Tuning in…"
    : (root.nowPlaying || "On air")

  readonly property string tooltip: root.stations[root.station].name + " · " + root.statusLine
    + "\nVolume " + root.volume + "%"
    + "\nClick: tuner · Middle-click: " + (root.wantPlaying ? "stop" : "play")
    + " · Right-click: next station · Scroll: volume"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐹"
    slotSize: Style.bar.iconSlot
    opacity: root.wantPlaying ? 1.0 : 0.55
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
    contentHeight: Style.space(450)

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
        if (root.cursor === root.station && root.wantPlaying) root.stop()
        else root.tune(root.cursor)
      }

      Rectangle {
        id: crt
        anchors.fill: parent
        color: root.screen
        radius: Style.space(10)
        clip: true

        // Power-on: the picture opens out of a bright line across the middle.
        property real boot: 1
        Connections {
          target: root
          function onOpenedChanged() {
            if (root.opened) { crt.boot = 0; bootAnim.restart() }
          }
        }
        NumberAnimation {
          id: bootAnim
          target: crt
          property: "boot"
          from: 0
          to: 1
          duration: Style.duration(260)
          easing.type: Easing.Bezier
          easing.bezierCurve: Style.easeOut
        }

        Item {
          id: picture
          anchors.fill: parent
          opacity: crt.boot
          transform: Scale {
            origin.y: crt.height / 2
            yScale: 0.04 + 0.96 * crt.boot
          }

          // Header: title, volume meter and status, then a rule.
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

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: title.verticalCenter
            anchors.rightMargin: Style.space(22)
            spacing: Style.space(14)

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "VOL "
                color: root.phosphor
                font.family: root.mono
                font.pixelSize: Style.space(14)
              }
              Repeater {
                model: 10
                Rectangle {
                  required property int index
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(6)
                  height: Style.space(8) + index * Style.space(1)
                  color: root.volume > index * 10 ? root.phosphor : root.phosphorFaint
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: !root.wantPlaying ? "□ OFF" : root.noSignal ? "◌ NO SIGNAL" : "■ ON AIR"
              color: root.phosphor
              font.family: root.mono
              font.pixelSize: Style.space(14)
            }
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
                height: Style.space(31)
                color: focused ? root.phosphor : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(64)
                  elide: Text.ElideRight
                  text: (row.current && root.wantPlaying ? "▶ " : "  ") + row.modelData.name
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
                    if (row.current && root.wantPlaying) root.stop()
                    else root.tune(row.index)
                  }
                }
              }
            }
          }

          // Right side: the signal scope, what's on air, and what just played.
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
              height: Style.space(140)
              color: "transparent"
              border.color: root.phosphorDim
              border.width: 1

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
                property color ink: root.phosphor
                onPhaseChanged: requestPaint()
                onInkChanged: requestPaint()
                Component.onCompleted: requestPaint()
                Connections {
                  target: root
                  function onLiveChanged() { scope.requestPaint() }
                  function onWantPlayingChanged() { scope.requestPaint() }
                  function onNoSignalChanged() { scope.requestPaint() }
                }
                onPaint: {
                  var ctx = getContext("2d")
                  ctx.clearRect(0, 0, width, height)
                  ctx.strokeStyle = ink
                  ctx.lineWidth = 2
                  ctx.shadowColor = ink
                  ctx.shadowBlur = 6
                  ctx.beginPath()
                  var mid = height / 2
                  // Tuning: jagged noise. Live: a layered wave. Off: flat.
                  var tuning = root.wantPlaying && !root.live && !root.noSignal
                  var amp = root.live ? height * 0.32 * (0.35 + root.volume / 150) : 0
                  for (var x = 0; x <= width; x += 2) {
                    var t = x / width
                    var y = mid
                      + amp * 0.6 * Math.sin(t * 6.3 * 3 + phase)
                      + amp * 0.3 * Math.sin(t * 6.3 * 7 - phase * 1.7)
                      + amp * 0.15 * Math.sin(t * 6.3 * 13 + phase * 2.3)
                    if (tuning) y += (Math.random() - 0.5) * height * 0.35
                    if (x === 0) ctx.moveTo(x, y)
                    else ctx.lineTo(x, y)
                  }
                  ctx.stroke()
                }
              }

              Text {
                anchors.centerIn: parent
                visible: root.noSignal
                text: "NO SIGNAL"
                color: root.phosphor
                font.family: root.mono
                font.pixelSize: Style.space(16)
                font.bold: true
                style: Text.Outline
                styleColor: root.screen
              }

              // Runs only while the tuner is open and there's something to draw.
              NumberAnimation {
                target: scope
                property: "phase"
                from: 0
                to: Math.PI * 2
                duration: 1600
                loops: Animation.Infinite
                running: root.opened && root.wantPlaying && !root.noSignal && !Style.reduceMotion
              }
            }

            Text {
              id: stationName
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: scopeFrame.bottom
              anchors.topMargin: Style.space(12)
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
              id: onAir
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: gameName.bottom
              anchors.topMargin: Style.space(8)
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: !root.wantPlaying ? "RADIO OFF"
                : root.noSignal ? "NO SIGNAL · RETRYING…"
                : root.buffering && !root.nowPlaying ? "TUNING IN…"
                : "♪ " + (root.nowPlaying || "ON AIR")
              color: root.phosphor
              font.family: root.mono
              font.pixelSize: Style.space(14)
            }

            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(2)
              visible: recent.count > 0

              Text {
                text: "RECENTLY PLAYED"
                color: root.phosphorDim
                font.family: root.mono
                font.pixelSize: Style.space(11)
                font.letterSpacing: 1
              }

              Repeater {
                id: recent
                // The song on air is already shown above.
                model: root.history.filter(function(h, i) { return !(i === 0 && h.title === root.nowPlaying) }).slice(0, 3)
                Text {
                  required property var modelData
                  width: side.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: modelData.tag + "  " + modelData.title
                  color: root.phosphorDim
                  font.family: root.mono
                  font.pixelSize: Style.space(12)
                }
              }
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
        }

        // Power-on line.
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width * (0.3 + 0.7 * Math.min(1, crt.boot * 2))
          height: 2
          color: root.phosphor
          opacity: crt.boot < 1 ? 1 - crt.boot : 0
        }

        // CRT scanlines, drawn once per size or colour change.
        Canvas {
          anchors.fill: parent
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.fillStyle = "rgba(0, 0, 0, 0.28)"
            for (var y = 0; y < height; y += 3) ctx.fillRect(0, y, width, 1)
          }
        }

        // The edge of the glass.
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

  Component.onDestruction: {
    root.wantPlaying = false
    player.running = false
  }
}

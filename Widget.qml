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
//
// Your own stations sit below the streams: a name and a hand-picked set of
// songs from the music folder setting, played shuffled on a loop. They're
// saved in the same state file. The folder is scanned only while the station
// editor is open, so an idle tuner starts no processes.
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

  // Stations the user made: { id, name, files: [absolute paths] }.
  property var customStations: []
  // The streams first, then the user's own; the tuner and every station
  // index work on this one list.
  readonly property var allStations: root.stations.concat(root.customStations.map(function(c) {
    return { key: "custom:" + c.id, name: c.name, tag: "YOU", custom: true, id: c.id, files: c.files,
      game: c.files.length + (c.files.length === 1 ? " SONG" : " SONGS") + " · YOUR MUSIC" }
  }))
  readonly property var current: root.allStations[Math.min(root.station, root.allStations.length - 1)]
  // The shuffled song order for the custom station playing.
  property var queue: []

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
  // The socket lives only in the private runtime directory, never a shared
  // /tmp, and carries a per-instance suffix so two shells can't collide.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string socketPath: runtimeDir === "" ? ""
    : runtimeDir + "/omarchy-nv-radio-" + Date.now().toString(36) + Math.floor(Math.random() * 1e9).toString(36) + ".sock"

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
  readonly property string musicDir: {
    var dir = String(root.setting("musicFolder", "~/Music") || "~/Music").trim()
    var home = Quickshell.env("HOME")
    if (dir === "~") return home
    if (dir.indexOf("~/") === 0) return home + dir.slice(1)
    return dir.charAt(0) === "/" ? dir : home + "/" + dir
  }

  onOpenedChanged: {
    cursor = station
    root.closeEditor()
  }

  // ------------------------------------------------------ station editor
  property bool editing: false
  property string editId: ""          // "" while making a new station
  property string draftName: ""
  property var draftFiles: ({})       // path -> true
  property int draftCount: 0
  property var library: []            // [{ path, label }] under musicDir
  property bool scanning: false
  property string libraryFilter: ""
  property int pickCursor: 0
  property string editFocus: "name"   // name | filter | list
  property bool confirmDelete: false
  property string editorNote: ""
  readonly property var shownLibrary: {
    var q = root.libraryFilter.trim().toLowerCase()
    if (q === "") return root.library
    return root.library.filter(function(s) { return s.label.toLowerCase().indexOf(q) !== -1 })
  }
  onShownLibraryChanged: pickCursor = Math.min(pickCursor, Math.max(0, shownLibrary.length - 1))

  Process {
    id: scanner
    command: ["find", "-L", root.musicDir, "-type", "f", "(",
      "-iname", "*.mp3", "-o", "-iname", "*.ogg", "-o", "-iname", "*.opus", "-o", "-iname", "*.oga",
      "-o", "-iname", "*.flac", "-o", "-iname", "*.m4a", "-o", "-iname", "*.aac", "-o", "-iname", "*.wav", ")"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLibrary(text)
    }
    onExited: root.scanning = false
  }

  function applyLibrary(output) {
    var prefix = root.musicDir.replace(/\/+$/, "") + "/"
    var seen = {}
    var songs = String(output || "").split("\n").filter(function(p) {
      if (p === "" || p.charAt(0) !== "/" || seen[p]) return false
      seen[p] = true
      return true
    }).slice(0, 10000).map(function(p) {
      var label = p.indexOf(prefix) === 0 ? p.slice(prefix.length) : p
      return { path: p, label: root.cleanTitle(label.replace(/\.[^./]+$/, "")) }
    })
    songs.sort(function(a, b) { return a.label.localeCompare(b.label) })
    root.library = songs
  }

  function openEditor(customId) {
    var found = root.customStations.filter(function(c) { return c.id === customId })[0]
    root.editId = found ? found.id : ""
    root.draftName = found ? found.name : ""
    var picked = {}
    if (found) found.files.forEach(function(f) { picked[f] = true })
    root.draftFiles = picked
    root.draftCount = Object.keys(picked).length
    root.libraryFilter = ""
    root.pickCursor = 0
    root.confirmDelete = false
    root.editorNote = ""
    root.editFocus = found ? "list" : "name"
    root.library = []
    root.scanning = true
    scanner.running = false
    scanner.running = true
    root.editing = true
  }

  function closeEditor() {
    root.editing = false
    scanner.running = false
    root.library = []
  }

  function togglePick(index) {
    var song = root.shownLibrary[index]
    if (!song) return
    var picked = Object.assign({}, root.draftFiles)
    if (picked[song.path]) delete picked[song.path]
    else picked[song.path] = true
    root.draftFiles = picked
    root.draftCount = Object.keys(picked).length
    root.editorNote = ""
  }

  // Ticks every song in view, or clears them all if they're already ticked.
  function toggleAllShown() {
    var shown = root.shownLibrary
    var picked = Object.assign({}, root.draftFiles)
    var all = shown.length > 0 && shown.every(function(s) { return picked[s.path] })
    shown.forEach(function(s) { if (all) delete picked[s.path]; else picked[s.path] = true })
    root.draftFiles = picked
    root.draftCount = Object.keys(picked).length
    root.editorNote = ""
  }

  function saveEditor() {
    var files = Object.keys(root.draftFiles)
    if (files.length === 0) {
      root.editorNote = "TICK AT LEAST ONE SONG"
      return
    }
    var name = root.cleanTitle(root.draftName).slice(0, 40) || "My Station"
    var currentKey = root.current.key
    var list = root.customStations.slice()
    var id = root.editId
    if (id === "") {
      id = Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
      list.push({ id: id, name: name, files: files })
    } else {
      list = list.map(function(c) { return c.id === id ? { id: id, name: name, files: files } : c })
    }
    root.customStations = list
    root.restoreStation(currentKey)
    root.closeEditor()
    root.tune(root.indexOfKey("custom:" + id), true)
  }

  function deleteEdited() {
    if (root.editId === "") return
    if (!root.confirmDelete) {
      root.confirmDelete = true
      return
    }
    var gone = "custom:" + root.editId
    var playingIt = root.current.key === gone
    var currentKey = root.current.key
    root.customStations = root.customStations.filter(function(c) { return c.id !== root.editId })
    root.closeEditor()
    if (playingIt) {
      root.stop()
      root.station = 0
    } else {
      root.restoreStation(currentKey)
    }
    root.cursor = root.station
    root.saveState()
  }

  function indexOfKey(key) {
    for (var i = 0; i < root.allStations.length; i++)
      if (root.allStations[i].key === key) return i
    return -1
  }

  // Keeps the same station selected after the list around it changes.
  function restoreStation(key) {
    var i = root.indexOfKey(key)
    root.station = i < 0 ? 0 : i
    root.cursor = root.station
  }

  // ------------------------------------------------------------ playback
  Process {
    id: player
    command: ["mpv", "--no-video", "--force-window=no", "--really-quiet", "--no-terminal",
      "--cache=yes", "--network-timeout=10", "--tls-verify=yes", "--volume=" + root.volume,
      "--title=New Vegas Radio", "--input-ipc-server=" + root.socketPath]
      .concat(root.current.custom ? ["--loop-playlist=inf", "--"].concat(root.queue) : [root.current.url])
    onRunningChanged: {
      if (running) {
        root.buffering = true
        connectRetry.restart()
      } else {
        ipc.connected = false
        connectRetry.stop()
        stallTimer.stop()
        stableTimer.stop()
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
        stableTimer.restart()
      }
    }
  }

  // The backoff starts over only after a minute of steady playback, so a
  // station that keeps connecting and dropping still backs off.
  Timer {
    id: stableTimer
    interval: 60000
    onTriggered: if (root.live) root.retries = 0
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
    if (root.socketPath === "") {
      console.warn("nv-radio: XDG_RUNTIME_DIR is not set; not starting playback")
      return
    }
    root.wantPlaying = true
    root.noSignal = false
    root.retries = 0
    retryTimer.stop()
    root.crackle()
    if (root.current.custom) root.queue = root.shuffled(root.current.files)
    player.running = true
  }

  function shuffled(list) {
    var out = list.slice()
    for (var i = out.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var t = out[i]; out[i] = out[j]; out[j] = t
    }
    return out
  }

  // Swaps what the running mpv plays: a stream, or a fresh shuffle of a
  // custom station's songs, looping.
  function loadCurrent() {
    if (root.current.custom) {
      root.queue = root.shuffled(root.current.files)
      var commands = [["set_property", "loop-playlist", "inf"], ["loadfile", root.queue[0], "replace"]]
      for (var i = 1; i < root.queue.length; i++) commands.push(["loadfile", root.queue[i], "append"])
      root.send(commands)
    } else {
      root.send([["set_property", "loop-playlist", "no"], ["loadfile", root.current.url, "replace"]])
    }
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

  // `reload` restarts the station even if it's the one playing, for a custom
  // station whose songs just changed.
  function tune(index, reload) {
    if (index < 0 || index >= root.allStations.length) return
    if (index === root.station && !reload) {
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
      root.loadCurrent()
    } else {
      // Mid-retry: start over on the new station now.
      player.running = false
      root.play()
    }
  }

  function nextStation() {
    var next = (root.station + 1) % root.allStations.length
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

  // Stream titles come from the network: one line, no control characters,
  // and a sane length before they reach the tooltip or the history.
  function cleanTitle(value) {
    if (typeof value !== "string") return ""
    return value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ")
      .replace(/\s+/g, " ").trim().slice(0, 256)
  }

  function remember(title) {
    if (title === "" || (root.history.length && root.history[0].title === title)) return
    var list = [{ title: title, tag: root.current.tag }].concat(root.history)
    root.history = list.slice(0, 4)
  }

  // -------------------------------------------------------- mpv IPC socket
  // One command, or a list of them written in one go.
  function send(command) {
    if (!ipc.connected) return
    var commands = Array.isArray(command[0]) ? command : [command]
    for (var i = 0; i < commands.length; i++)
      ipc.write(JSON.stringify({ command: commands[i] }) + "\n")
    ipc.flush()
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
          var title = root.cleanTitle(msg.data)
          // Before a stream sends a song title, or a song file's tags are read,
          // mpv reports the file name.
          root.nowPlaying = /\.(ogg|oga|opus|mp3|flac|m4a|aac|wav)$/i.test(title) || title === "None" ? "" : title
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
        if (Array.isArray(s.custom)) {
          root.customStations = s.custom.filter(function(c) {
            return c && typeof c.id === "string" && /^[a-z0-9]{1,32}$/.test(c.id)
              && typeof c.name === "string" && Array.isArray(c.files)
          }).map(function(c) {
            return { id: c.id, name: root.cleanTitle(c.name).slice(0, 40) || "My Station",
              files: c.files.filter(function(f) { return typeof f === "string" && f.charAt(0) === "/" }) }
          }).filter(function(c) { return c.files.length > 0 })
        }
        var byKey = typeof s.stationKey === "string" ? root.indexOfKey(s.stationKey) : -1
        if (byKey >= 0) root.station = byKey
        else if (Number.isInteger(s.station) && s.station >= 0 && s.station < root.stations.length) root.station = s.station
        if (Number.isInteger(s.volume) && s.volume >= 0 && s.volume <= 100) root.volume = s.volume
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
    stateFile.setText(JSON.stringify({ station: root.station, stationKey: root.current.key,
      volume: root.volume, custom: root.customStations }, null, 2))
  }

  // ----------------------------------------------------------------- bar
  readonly property string statusLine: !root.wantPlaying ? "Off"
    : root.noSignal ? "No signal, retrying"
    : root.buffering && !root.nowPlaying ? "Tuning in…"
    : (root.nowPlaying || "On air")

  readonly property string tooltip: root.current.name + " · " + root.statusLine
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
      id: keys
      anchors.fill: parent
      // While a text field in the editor has the keyboard, it gets every key.
      blocked: root.editing && root.editFocus !== "list"
      readonly property int rowCount: root.allStations.length + 1   // + NEW STATION

      function cycleFocus(direction) {
        var order = ["name", "filter", "list"]
        root.editFocus = order[(order.indexOf(root.editFocus) + direction + order.length) % order.length]
      }

      function applyFocus() {
        if (!root.editing) { keys.forceActiveFocus(); return }
        var field = root.editFocus === "list" ? null : fields.input(root.editFocus)
        if (field) field.forceActiveFocus()
        else keys.forceActiveFocus()
      }

      Connections {
        target: root
        function onEditingChanged() {
          if (root.editing) {
            fields.input("name").text = root.draftName
            fields.input("filter").text = ""
          }
          keys.applyFocus()
        }
        function onEditFocusChanged() { keys.applyFocus() }
      }

      onCloseRequested: {
        if (root.editing) root.closeEditor()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.editing) keys.cycleFocus(direction)
        else root.switchPanel(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (root.editing) {
          if (dy !== 0 && root.shownLibrary.length > 0)
            root.pickCursor = Math.max(0, Math.min(root.shownLibrary.length - 1, root.pickCursor + dy))
          return
        }
        if (dy !== 0) root.cursor = (root.cursor + dy + keys.rowCount) % keys.rowCount
        if (dx !== 0) root.changeVolume(dx * 5)
      }
      // Enter or Space: tune to the highlighted station, or stop it if it's the
      // one playing. In the editor, tick or untick the highlighted song.
      onActivateRequested: {
        if (root.editing) root.togglePick(root.pickCursor)
        else if (root.cursor === root.allStations.length) root.openEditor("")
        else if (root.cursor === root.station && root.wantPlaying) root.stop()
        else root.tune(root.cursor)
      }
      onDeleteRequested: {
        if (root.editing) {
          root.deleteEdited()
        } else {
          var row = root.allStations[root.cursor]
          if (row && row.custom) { root.openEditor(row.id); root.confirmDelete = true }
        }
      }
      onTextKey: function(text, modifiers) {
        if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        var t = text.toLowerCase()
        if (root.editing) {
          if (t === "a") root.toggleAllShown()
          else if (t === "s") root.saveEditor()
          else if (t === "/" || t === "f") root.editFocus = "filter"
          else if (t === "n") root.editFocus = "name"
        } else {
          var row = root.allStations[root.cursor]
          if (t === "e" && row && row.custom) root.openEditor(row.id)
          else if (t === "n") root.openEditor("")
        }
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
            text: !root.editing ? "WASTELAND RADIO" : root.editId === "" ? "NEW STATION" : "EDIT STATION"
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

          // Station list: the streams, your stations, then + NEW STATION.
          ListView {
            id: list
            visible: !root.editing
            anchors.left: parent.left
            anchors.top: rule.bottom
            anchors.bottom: footer.top
            anchors.leftMargin: Style.space(16)
            anchors.topMargin: Style.space(10)
            anchors.bottomMargin: Style.space(10)
            width: Style.space(300)
            spacing: Style.space(2)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.allStations.concat([{ key: "new", name: "+ NEW STATION", tag: "", isNew: true }])

            Connections {
              target: root
              function onCursorChanged() { list.positionViewAtIndex(root.cursor, ListView.Contain) }
            }

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool current: index === root.station
              readonly property bool focused: index === root.cursor || rowMouse.containsMouse
              width: list.width - Style.space(6)
              height: Style.space(31)
              color: focused ? root.phosphor : "transparent"

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(64)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: row.modelData.isNew ? row.modelData.name
                  : (row.current && root.wantPlaying ? "▶ " : "  ") + row.modelData.name
                color: row.focused ? root.screen : row.modelData.isNew ? root.phosphorDim : root.phosphor
                font.family: root.mono
                font.pixelSize: Style.space(15)
                font.bold: row.current && !row.modelData.isNew
              }

              // Your stations show EDIT while highlighted; the streams their game.
              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.custom && row.focused ? "E EDIT" : row.modelData.tag
                color: row.focused ? root.screen : root.phosphorDim
                font.family: root.mono
                font.pixelSize: Style.space(12)
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onEntered: root.cursor = row.index
                onClicked: function(mouse) {
                  if (row.modelData.isNew) root.openEditor("")
                  else if (mouse.button === Qt.RightButton || (mouse.x > width - Style.space(64) && row.modelData.custom)) {
                    if (row.modelData.custom) root.openEditor(row.modelData.id)
                  }
                  else if (row.current && root.wantPlaying) root.stop()
                  else root.tune(row.index)
                }
              }
            }
          }

          // A scroll bar, once there are more stations than fit.
          Rectangle {
            visible: !root.editing && list.contentHeight > list.height
            anchors.right: list.right
            y: list.y + list.visibleArea.yPosition * list.height
            width: Style.space(3)
            height: list.visibleArea.heightRatio * list.height
            color: root.phosphorDim
          }

          // Right side: the signal scope, what's on air, and what just played.
          Item {
            id: side
            visible: !root.editing
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
              textFormat: Text.PlainText
              text: root.current.name.toUpperCase()
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
              text: root.current.game
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

          // Station editor: a name, a filter, and the songs in the music folder to tick.
          Item {
            id: editor
            visible: root.editing
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: rule.bottom
            anchors.bottom: footer.top
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(16)
            anchors.topMargin: Style.space(10)
            anchors.bottomMargin: Style.space(10)

            Column {
              id: fields
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              spacing: Style.space(6)

              function input(key) {
                var item = fieldRepeater.itemAt(key === "name" ? 0 : 1)
                return item ? item.input : null
              }

              Repeater {
                id: fieldRepeater
                model: [
                  { key: "name", label: "NAME", placeholder: "My Station", max: 40 },
                  { key: "filter", label: "FIND", placeholder: "filter songs  ( / )", max: 256 }
                ]

                Rectangle {
                  id: field
                  required property var modelData
                  property alias input: entry
                  width: fields.width
                  height: Style.space(30)
                  color: "transparent"
                  border.color: entry.activeFocus ? root.phosphor : root.phosphorFaint
                  border.width: 1

                  Text {
                    id: fieldLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(52)
                    text: field.modelData.label
                    color: root.phosphorDim
                    font.family: root.mono
                    font.pixelSize: Style.space(12)
                  }

                  TextInput {
                    id: entry
                    anchors.left: fieldLabel.right
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    clip: true
                    color: root.phosphor
                    selectionColor: root.phosphorDim
                    selectedTextColor: root.screen
                    font.family: root.mono
                    font.pixelSize: Style.space(15)
                    maximumLength: field.modelData.max
                    onTextEdited: {
                      if (field.modelData.key === "name") root.draftName = text
                      else root.libraryFilter = text
                    }
                    onActiveFocusChanged: if (activeFocus) root.editFocus = field.modelData.key
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) {
                        root.closeEditor(); event.accepted = true
                      } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                        keys.cycleFocus((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
                        event.accepted = true
                      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Down) {
                        root.editFocus = "list"; event.accepted = true
                      }
                    }

                    Text {
                      anchors.fill: parent
                      verticalAlignment: Text.AlignVCenter
                      visible: entry.text === "" && !entry.activeFocus
                      text: field.modelData.placeholder
                      color: root.phosphorFaint
                      font: entry.font
                    }
                  }
                }
              }
            }

            Text {
              id: tally
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: fields.bottom
              anchors.topMargin: Style.space(8)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.confirmDelete ? "PRESS X AGAIN TO DELETE THIS STATION"
                : root.editorNote !== "" ? root.editorNote
                : root.scanning && root.library.length === 0 ? "SCANNING " + root.musicDir + "…"
                : root.library.length === 0 ? "NO MUSIC FOUND IN " + root.musicDir
                : root.draftCount + " TICKED · " + root.shownLibrary.length + " OF " + root.library.length + " SHOWN"
              color: root.confirmDelete || root.editorNote !== "" ? root.phosphor : root.phosphorDim
              font.family: root.mono
              font.pixelSize: Style.space(12)
              font.bold: root.confirmDelete || root.editorNote !== ""
            }

            ListView {
              id: songs
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: tally.bottom
              anchors.bottom: buttons.top
              anchors.topMargin: Style.space(6)
              anchors.bottomMargin: Style.space(8)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: root.shownLibrary

              Connections {
                target: root
                function onPickCursorChanged() { songs.positionViewAtIndex(root.pickCursor, ListView.Contain) }
              }

              delegate: Rectangle {
                id: song
                required property var modelData
                required property int index
                readonly property bool picked: root.draftFiles[modelData.path] === true
                readonly property bool focused: (index === root.pickCursor && root.editFocus === "list") || songMouse.containsMouse
                width: songs.width - Style.space(6)
                height: Style.space(24)
                color: focused ? root.phosphor : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideMiddle
                  textFormat: Text.PlainText
                  text: (song.picked ? "[■] " : "[ ] ") + song.modelData.label
                  color: song.focused ? root.screen : song.picked ? root.phosphor : root.phosphorDim
                  font.family: root.mono
                  font.pixelSize: Style.space(13)
                }

                MouseArea {
                  id: songMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.pickCursor = song.index
                    root.editFocus = "list"
                    root.togglePick(song.index)
                  }
                }
              }
            }

            Rectangle {
              visible: songs.contentHeight > songs.height
              anchors.right: songs.right
              y: songs.y + songs.visibleArea.yPosition * songs.height
              width: Style.space(3)
              height: songs.visibleArea.heightRatio * songs.height
              color: root.phosphorDim
            }

            Row {
              id: buttons
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(10)

              Repeater {
                model: root.editId === "" ? ["SAVE", "CANCEL"] : ["SAVE", "CANCEL", "DELETE"]
                Rectangle {
                  id: action
                  required property string modelData
                  width: actionText.implicitWidth + Style.space(20)
                  height: Style.space(24)
                  color: actionMouse.containsMouse ? root.phosphor : "transparent"
                  border.color: root.phosphor
                  border.width: 1
                  Text {
                    id: actionText
                    anchors.centerIn: parent
                    text: "[ " + action.modelData + " ]"
                    color: actionMouse.containsMouse ? root.screen : root.phosphor
                    font.family: root.mono
                    font.pixelSize: Style.space(12)
                    font.bold: true
                  }
                  MouseArea {
                    id: actionMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      if (action.modelData === "SAVE") root.saveEditor()
                      else if (action.modelData === "CANCEL") root.closeEditor()
                      else root.deleteEdited()
                    }
                  }
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
              text: !root.editing ? "↑↓ SELECT   ⏎ PLAY/STOP   ←→ VOL   N NEW   ESC CLOSE"
                : root.editFocus === "list" ? "␣ TICK   A ALL   / FIND   N NAME   S SAVE   ESC CANCEL"
                : "TYPE   ⏎ TO SONGS   TAB NEXT   ESC CANCEL"
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

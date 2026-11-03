import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

BarWidget {
  id: root
  moduleName: "damienzonly.stats"

  readonly property real historySeconds: Math.max(10, Number(setting("historySeconds", 300)))
  readonly property real sampleInterval: Math.max(0.5, Number(setting("sampleInterval", 1)))
  readonly property int historyLength: Math.max(10, Math.round(historySeconds / sampleInterval))
  // Choices offered in the popup's GRAPHS section.
  readonly property var windowPresets: [
    { label: "1m", value: 60 }, { label: "5m", value: 300 },
    { label: "15m", value: 900 }, { label: "1h", value: 3600 }
  ]
  readonly property var intervalPresets: [
    { label: "1s", value: 1 }, { label: "2s", value: 2 }, { label: "5s", value: 5 }
  ]

  // Persist a setting to this widget's shell.json entry; the shell pushes it
  // back into `settings`, so the bindings above update live.
  function saveSetting(key, value) {
    Quickshell.execDetached(["omarchy", "bar", "set", root.moduleName, key, String(value), "--json"])
  }
  readonly property int barPoints: 24
  // VPN/tunnel/container interfaces carry traffic already counted on the
  // physical link, so they are left out of the totals.
  readonly property var virtualIfaceRe: /^(lo|tun|tap|tailscale|wg|docker|veth|br-|virbr|vnet|zt)/

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")

  property var cpuHist: []
  property var memHist: []
  property var rxHist: []
  property var txHist: []
  property var coreUsage: []
  property real cpuNow: 0
  property real memNow: 0
  property real rxNow: 0
  property real txNow: 0
  property var mem: ({})
  property var temps: ({ cpu: 0, nvme: 0 })
  property int freqMhz: 0
  property var ifaces: []          // [{ name, rx, tx, rxTotal, txTotal, ip }]
  property var ifaceHist: ({})     // name -> { rx: [], tx: [] }
  // Row model for the popup; only reassigned when the set or order of
  // interfaces changes, so rows aren't recreated every sample.
  property var ifaceNames: [""]
  // "" shows the aggregate of physical interfaces; otherwise one interface.
  property string selectedIface: ""

  readonly property var netRxHist: selectedIface && ifaceHist[selectedIface] ? ifaceHist[selectedIface].rx : rxHist
  readonly property var netTxHist: selectedIface && ifaceHist[selectedIface] ? ifaceHist[selectedIface].tx : txHist
  readonly property real netRxNow: netRxHist.length ? netRxHist[netRxHist.length - 1] : 0
  readonly property real netTxNow: netTxHist.length ? netTxHist[netTxHist.length - 1] : 0
  property var topCpu: []
  property var topMem: []
  property var topGpu: []
  property var topVram: []
  // One entry per GPU from the sampler: { id, vendor, driver, name, busy,
  // memUsed, memTotal, gttUsed, gttTotal, temp, source }. memTotal is 0 for
  // integrated GPUs, which use shared system memory.
  property var gpus: []
  property var gpuHistById: ({})   // id -> { busy: [], mem: [] } (mem in %)
  property string selectedGpu: ""
  readonly property bool hasGpu: gpus.length > 0
  readonly property var gpu: {
    for (var i = 0; i < gpus.length; i++) if (gpus[i].id === selectedGpu) return gpus[i]
    return gpus.length ? gpus[0] : { id: "", name: "", busy: 0, memUsed: 0, memTotal: 0, gttUsed: 0, gttTotal: 0, temp: 0 }
  }
  readonly property var gpuHist: gpuHistById[gpu.id] ? gpuHistById[gpu.id].busy : []
  readonly property var vramHist: gpu.memTotal > 0 && gpuHistById[gpu.id] ? gpuHistById[gpu.id].mem : []
  readonly property real gpuNow: gpu.busy
  readonly property real vramNow: gpu.memTotal > 0 ? 100 * gpu.memUsed / gpu.memTotal : 0
  readonly property var topGpuSel: topGpu.filter(function(r) { return r.gpu === gpu.id })
  readonly property var topVramSel: topVram.filter(function(r) { return r.gpu === gpu.id && r.vram > 0 })

  function gpuShortName(g) {
    var vendor = { amd: "AMD", intel: "Intel", nvidia: "NVIDIA", apple: "Apple" }[g.vendor] || g.driver
    return vendor + (g.memTotal > 0 ? "" : " (integrated)")
  }
  property var ips: ({})

  // Series colors come from the theme: download = accent, upload = the first
  // theme color clearly distinct from the accent (yellow preferred),
  // memory = magenta. Graphs sit on the theme's darkest background so the
  // lines always contrast with what's behind them.
  readonly property color rxColor: Commons.Color.accent
  readonly property color cpuColor: Commons.Color.accent
  property var txCandidates: ["#e8a04c"]
  readonly property color txColor: pickDistinct(txCandidates, rxColor)
  property color memColor: "#c678dd"
  property color gpuColor: "#56b6c2"
  property color graphBackground: Qt.darker(Commons.Color.background, 1.6)

  // First candidate far enough from `avoid` (themes often use blue as the
  // accent); falls back to the most distant one.
  function pickDistinct(candidates, avoid) {
    var a = Qt.color(avoid), best = candidates[0], bestD = -1
    for (var i = 0; i < candidates.length; i++) {
      var c = Qt.color(candidates[i])
      var d = Math.sqrt(Math.pow(c.r - a.r, 2) + Math.pow(c.g - a.g, 2) + Math.pow(c.b - a.b, 2))
      if (d > 0.3) return candidates[i]
      if (d > bestD) { bestD = d; best = candidates[i] }
    }
    return best
  }

  function themeColor(toml, key, fallback) {
    var m = toml.match(new RegExp("^\\s*" + key + "\\s*=\\s*\"(#[0-9a-fA-F]{6})\"", "m"))
    return m ? m[1] : fallback
  }

  FileView {
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var toml = String(text() || "")
      var tx = []
      var keys = ["yellow", "red", "green", "magenta", "cyan", "blue"]
      for (var i = 0; i < keys.length; i++) {
        var v = root.themeColor(toml, keys[i], "")
        if (v) tx.push(v)
      }
      tx.push("#e8a04c")
      root.txCandidates = tx
      root.memColor = root.themeColor(toml, "magenta", "#c678dd")
      root.gpuColor = root.themeColor(toml, "cyan", "#56b6c2")
      root.graphBackground = root.themeColor(toml, "darker_background", Qt.darker(Commons.Color.background, 1.6))
    }
  }

  property var _prevCpu: null
  property var _prevNet: null
  property real _prevTime: 0

  property bool popupOpen: false
  function close() { popupOpen = false }

  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  function push(list, value) {
    var next = list.length >= historyLength ? list.slice(list.length - historyLength + 1) : list.slice()
    next.push(value)
    return next
  }

  function ingest(line) {
    var s
    try { s = JSON.parse(line) } catch (e) { return }
    var now = Date.now() / 1000
    var dt = _prevTime > 0 ? Math.max(0.1, now - _prevTime) : sampleInterval

    if (_prevCpu && _prevCpu.length === s.cpu.length) {
      var usage = []
      for (var i = 0; i < s.cpu.length; i++) {
        var dTotal = s.cpu[i][0] - _prevCpu[i][0]
        var dIdle = s.cpu[i][1] - _prevCpu[i][1]
        usage.push(dTotal > 0 ? Math.max(0, Math.min(100, 100 * (1 - dIdle / dTotal))) : 0)
      }
      cpuNow = usage[0]
      coreUsage = usage.slice(1)
      cpuHist = push(cpuHist, cpuNow)
    }
    _prevCpu = s.cpu

    mem = s.mem
    if (s.mem.MemTotal > 0) {
      memNow = 100 * (1 - s.mem.MemAvailable / s.mem.MemTotal)
      memHist = push(memHist, memNow)
    }

    var list = []
    var hist = {}
    var rx = 0, tx = 0
    for (var name in s.net) {
      var cur = s.net[name]
      var prev = _prevNet ? _prevNet[name] : null
      var r = prev ? Math.max(0, (cur[0] - prev[0]) / dt) : 0
      var t = prev ? Math.max(0, (cur[1] - prev[1]) / dt) : 0
      var isVirtual = virtualIfaceRe.test(name)
      if (!isVirtual) { rx += r; tx += t }
      if (name !== "lo" && (cur[0] > 0 || cur[1] > 0)) {
        list.push({ name: name, rx: r, tx: t, rxTotal: cur[0], txTotal: cur[1], virtual: isVirtual })
        var old = ifaceHist[name] || { rx: [], tx: [] }
        hist[name] = prev ? { rx: push(old.rx, r), tx: push(old.tx, t) } : old
      }
    }
    ifaceHist = hist
    if (selectedIface && !hist[selectedIface]) selectedIface = ""
    if (_prevNet) {
      rxNow = rx
      txNow = tx
      rxHist = push(rxHist, rx)
      txHist = push(txHist, tx)
    }
    list.sort(function(a, b) {
      if (a.virtual !== b.virtual) return a.virtual ? 1 : -1
      return a.name.localeCompare(b.name)
    })
    ifaces = list
    var names = [""].concat(list.map(function(e) { return e.name }))
    if (names.join("|") !== ifaceNames.join("|")) ifaceNames = names
    _prevNet = s.net
    _prevTime = now

    if (s.gpus) {
      var gh = {}
      for (var gi = 0; gi < s.gpus.length; gi++) {
        var g = s.gpus[gi]
        var oldG = gpuHistById[g.id] || { busy: [], mem: [] }
        gh[g.id] = {
          busy: push(oldG.busy, g.busy),
          mem: push(oldG.mem, g.memTotal > 0 ? 100 * g.memUsed / g.memTotal : 0)
        }
      }
      gpuHistById = gh
      gpus = s.gpus
      // Default to the first discrete GPU (it has dedicated memory).
      if (!gh[selectedGpu]) {
        var pick = s.gpus.length ? s.gpus[0].id : ""
        for (var gj = 0; gj < s.gpus.length; gj++) if (s.gpus[gj].memTotal > 0) { pick = s.gpus[gj].id; break }
        selectedGpu = pick
      }
    }

    temps = s.temp
    freqMhz = s.freq
  }

  function ifaceInfo(name) {
    if (name === "") return { name: "", rx: rxNow, tx: txNow, virtual: false }
    for (var i = 0; i < ifaces.length; i++) if (ifaces[i].name === name) return ifaces[i]
    return { name: name, rx: 0, tx: 0, rxTotal: 0, txTotal: 0, virtual: false }
  }

  function formatRate(bytes) {
    if (bytes >= 1e9) return (bytes / 1e9).toFixed(1) + "G"
    if (bytes >= 1e6) return (bytes / 1e6).toFixed(bytes >= 1e7 ? 0 : 1) + "M"
    if (bytes >= 1e3) return Math.round(bytes / 1e3) + "K"
    return Math.round(bytes) + "B"
  }

  function formatBytes(bytes) {
    if (bytes >= 1e12) return (bytes / 1e12).toFixed(2) + " TB"
    if (bytes >= 1e9) return (bytes / 1e9).toFixed(2) + " GB"
    if (bytes >= 1e6) return (bytes / 1e6).toFixed(1) + " MB"
    if (bytes >= 1e3) return (bytes / 1e3).toFixed(0) + " KB"
    return Math.round(bytes) + " B"
  }

  function formatKb(kb) { return formatBytes(kb * 1024) }

  function tempColor(c) {
    if (c >= 90) return Commons.Color.urgent
    return root.bar.foreground
  }

  Process {
    id: sampler
    command: ["python3", "-B", root.pluginDir + "sampler.py", String(root.sampleInterval)]
    running: true
    stdout: SplitParser { onRead: function(data) { root.ingest(data) } }
    // A deliberate stop (interval change) restarts right away; a crash waits.
    property bool restarting: false
    onExited: {
      if (restarting) { restarting = false; running = true }
      else restartTimer.restart()
    }
  }

  // The sampler takes its interval as an argument, so restart it on change.
  onSampleIntervalChanged: {
    if (!sampler.running) return
    sampler.restarting = true
    sampler.running = false
  }

  Timer {
    id: restartTimer
    interval: 3000
    onTriggered: sampler.running = true
  }

  Process {
    id: procs
    command: ["python3", "-B", root.pluginDir + "procs.py", "6"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          root.topCpu = d.cpu
          root.topMem = d.mem
          root.topGpu = d.gpu || []
          root.topVram = d.vram || []
          root.ips = d.ips
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 3000
    repeat: true
    triggeredOnStart: true
    running: root.popupOpen
    onTriggered: if (!procs.running) procs.running = true
  }

  IpcHandler {
    target: "damienzonly.stats"
    function toggle(): string { root.popupOpen = !root.popupOpen; return "ok" }
  }

  // ------------------------------------------------------------------ bar

  component BarStat: Row {
    id: stat
    property var values: []
    property var values2: []
    property real maximum: 0
    property real minimumScale: 1
    property color color: root.bar.barForeground
    property color color2: root.bar.barForeground
    property string label: ""
    property string label2: ""
    property color labelColor: root.bar.barForeground
    property color label2Color: root.bar.barForeground
    property string icon: ""

    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: stat.icon
      visible: text !== ""
      color: Qt.darker(root.bar.barForeground, 1.3)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Graph {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(30)
      height: Math.round(root.barSize * 0.5)
      points: root.barPoints
      values: stat.values
      values2: stat.values2
      maximum: stat.maximum
      minimumScale: stat.minimumScale
      color: stat.color
      color2: stat.color2
      background: root.graphBackground
      fillOpacity: 0.35
      lineWidth: 1
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: stat.label
      color: stat.labelColor
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: stat.label2
      visible: text !== ""
      color: stat.label2Color
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(10)

    BarStat {
      anchors.verticalCenter: parent.verticalCenter
      icon: "󰻠"
      values: root.cpuHist
      maximum: 100
      color: root.cpuColor
      label: Math.round(root.cpuNow) + "%"
    }

    BarStat {
      anchors.verticalCenter: parent.verticalCenter
      icon: "󰍛"
      values: root.memHist
      maximum: 100
      color: root.memColor
      label: Math.round(root.memNow) + "%"
    }

    BarStat {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.hasGpu
      icon: "󰢮"
      values: root.gpuHist
      values2: root.vramHist
      maximum: 100
      color: root.gpuColor
      color2: root.memColor
      label: Math.round(root.gpuNow) + "%"
    }

    BarStat {
      anchors.verticalCenter: parent.verticalCenter
      icon: "󰛳"
      values: root.rxHist
      values2: root.txHist
      minimumScale: 10240
      color: root.rxColor
      color2: root.txColor
      label: "↓" + root.formatRate(root.rxNow)
      labelColor: root.rxColor
      label2: "↑" + root.formatRate(root.txNow)
      label2Color: root.txColor
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: root.popupOpen = !root.popupOpen
  }

  // ---------------------------------------------------------------- popup

  component Section: BorderSurface {
    default property alias content: inner.data
    property alias title: header.text
    property alias trailing: trailingText.text
    readonly property real pad: Style.space(10)
    width: parent ? parent.width : 0
    height: inner.implicitHeight + pad * 2
    radius: Style.spacing.labelGap * 2
    color: Commons.Util.alpha(root.bar.foreground, 0.03)
    borderSpec: Border.flat(Commons.Util.alpha(root.bar.foreground, 0.14), 1)

    Column {
      id: inner
      x: parent.pad
      y: parent.pad
      width: parent.width - parent.pad * 2
      spacing: Style.space(6)

    Item {
      width: parent.width
      height: header.implicitHeight

      PanelSectionHeader {
        id: header
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      Text {
        id: trailingText
        anchors.right: parent.right
        anchors.verticalCenter: header.verticalCenter
        textFormat: Text.PlainText
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
    }
  }

  component KeyValue: Item {
    property string key: ""
    property string value: ""
    property color valueColor: root.bar.foreground
    width: parent ? parent.width : 0
    height: k.implicitHeight

    Text {
      id: k
      textFormat: Text.PlainText
      text: parent.key
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.right: parent.right
      textFormat: Text.PlainText
      text: parent.value
      color: parent.valueColor
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component BigGraph: BorderSurface {
    id: bg
    property alias values: g.values
    property alias values2: g.values2
    property alias maximum: g.maximum
    property alias minimumScale: g.minimumScale
    property alias lineColor: g.color
    property alias lineColor2: g.color2
    width: parent ? parent.width : 0
    height: Style.space(64)
    radius: Style.spacing.labelGap
    color: root.graphBackground
    borderSpec: Border.flat(Commons.Util.alpha(root.bar.foreground, 0.12), 1)

    Graph {
      id: g
      anchors.fill: parent
      anchors.margins: Style.space(3)
      points: root.historyLength
      showGrid: true
      gridColor: Commons.Util.alpha(root.bar.foreground, 0.08)
    }
  }

  component ProcList: Column {
    id: pl
    property var model: []
    property string mode: "cpu"   // cpu | rss | gpu | vram
    spacing: Style.space(2)

    Repeater {
      model: pl.model

      Item {
        required property var modelData
        width: pl.width
        height: pname.implicitHeight

        Text {
          id: pname
          width: parent.width - pval.implicitWidth - Style.space(6)
          textFormat: Text.PlainText
          text: modelData.name
          elide: Text.ElideRight
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: pval
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: pl.mode === "rss" ? root.formatKb(modelData.rss)
            : pl.mode === "vram" ? root.formatKb(modelData.vram)
            : pl.mode === "gpu" ? modelData.busy.toFixed(1) + "%"
            : modelData.cpu.toFixed(1) + "%"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    readonly property real columnWidth: Style.space(400)
    contentWidth: popup.fittedContentWidth(columnWidth * 2 + Style.space(12))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Row {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      Column {
        width: (column.width - column.spacing) / 2
        spacing: Style.space(12)

      // CPU
      Section {
        title: "CPU"
        trailing: Math.round(root.cpuNow) + "%  ·  " + (root.freqMhz / 1000).toFixed(2) + " GHz"

        BigGraph {
          values: root.cpuHist
          maximum: 100
          lineColor: root.cpuColor
        }

        Row {
          id: cores
          width: parent.width
          height: Style.space(28)
          spacing: Style.space(2)

          Repeater {
            model: root.coreUsage

            Item {
              required property var modelData
              width: (cores.width - cores.spacing * (root.coreUsage.length - 1)) / Math.max(1, root.coreUsage.length)
              height: cores.height

              Rectangle {
                anchors.fill: parent
                radius: 2
                color: Commons.Util.alpha(root.bar.foreground, 0.08)
              }

              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: parent.height * modelData / 100
                radius: 2
                color: Commons.Color.accent
                Behavior on height { NumberAnimation { duration: 200 } }
              }
            }
          }
        }
      }

      // Memory
      Section {
        title: "MEMORY"
        trailing: root.mem.MemTotal
          ? root.formatKb(root.mem.MemTotal - root.mem.MemAvailable) + " / " + root.formatKb(root.mem.MemTotal) + "  ·  " + Math.round(root.memNow) + "%"
          : ""

        BigGraph {
          values: root.memHist
          maximum: 100
          lineColor: root.memColor
        }

        Grid {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(16)
          rowSpacing: Style.space(2)

          KeyValue { width: (parent.width - Style.space(16)) / 2; key: "Available"; value: root.formatKb(root.mem.MemAvailable || 0) }
          KeyValue { width: (parent.width - Style.space(16)) / 2; key: "Cache"; value: root.formatKb((root.mem.Cached || 0) + (root.mem.Buffers || 0) + (root.mem.SReclaimable || 0)) }
          KeyValue { width: (parent.width - Style.space(16)) / 2; key: "Shared"; value: root.formatKb(root.mem.Shmem || 0) }
          KeyValue {
            width: (parent.width - Style.space(16)) / 2
            key: "Swap"
            value: root.mem.SwapTotal
              ? root.formatKb(root.mem.SwapTotal - root.mem.SwapFree) + " / " + root.formatKb(root.mem.SwapTotal)
              : "—"
          }
        }
      }

      // GPU
      Section {
        visible: root.hasGpu
        title: "GPU"
        trailing: Math.round(root.gpuNow) + "%" + (root.gpu.temp > 0 ? "  ·  " + root.gpu.temp + "°C" : "")

        // Device picker, only when there's more than one GPU.
        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: root.gpus.length > 1

          Repeater {
            model: root.gpus

            BorderSurface {
              id: chip
              required property var modelData
              readonly property bool selected: root.gpu.id === modelData.id
              width: chipText.implicitWidth + Style.space(16)
              height: chipText.implicitHeight + Style.space(8)
              radius: Style.spacing.labelGap
              color: selected ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
                : (chipHover.hovered ? Commons.Util.alpha(root.bar.foreground, 0.06) : "transparent")
              borderSpec: Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent)

              Text {
                id: chipText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.gpuShortName(chip.modelData) + "  " + Math.round(chip.modelData.busy) + "%"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: chip.selected
              }

              HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.selectedGpu = chip.modelData.id }
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.gpu.name + (root.gpu.source === "none" ? "  ·  nvidia-smi not found" : "")
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        BigGraph {
          values: root.gpuHist
          values2: root.vramHist
          maximum: 100
          lineColor: root.gpuColor
          lineColor2: root.memColor
        }

        Flow {
          width: parent.width
          spacing: Style.space(16)

          Repeater {
            model: [
              { label: "Load", color: root.gpuColor, text: Math.round(root.gpuNow) + "%" },
              root.gpu.memTotal > 0
                ? { label: "VRAM", color: root.memColor, text: root.formatBytes(root.gpu.memUsed) + " / " + root.formatBytes(root.gpu.memTotal) }
                : { label: "Shared memory", color: "transparent", text: root.formatBytes(root.gpu.memUsed) },
              { label: "GTT", color: "transparent", text: root.gpu.gttTotal > 0 ? root.formatBytes(root.gpu.gttUsed) + " / " + root.formatBytes(root.gpu.gttTotal) : "" }
            ].filter(function(e) { return e.text !== "" })

            Row {
              required property var modelData
              spacing: Style.space(5)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: modelData.color !== "transparent"
                width: Style.space(10)
                height: Style.space(10)
                radius: width / 2
                color: modelData.color
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData.label + "  " + modelData.text
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // Graph history window and sampling rate, saved to shell.json.
      Section {
        title: "GRAPHS"
        trailing: root.historyLength + " samples"

        Repeater {
          model: [
            { label: "Window", key: "historySeconds", presets: root.windowPresets, current: root.historySeconds },
            { label: "Interval", key: "sampleInterval", presets: root.intervalPresets, current: root.sampleInterval }
          ]

          Row {
            id: optRow
            required property var modelData
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(70)
              textFormat: Text.PlainText
              text: optRow.modelData.label
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: optRow.modelData.presets

              BorderSurface {
                id: optChip
                required property var modelData
                readonly property bool selected: Number(optRow.modelData.current) === modelData.value
                width: Style.space(44)
                height: optText.implicitHeight + Style.space(8)
                radius: Style.spacing.labelGap
                color: selected ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
                  : (optHover.hovered ? Commons.Util.alpha(root.bar.foreground, 0.06) : "transparent")
                borderSpec: Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent)

                Text {
                  id: optText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: optChip.modelData.label
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: optChip.selected
                }

                HoverHandler { id: optHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  onTapped: if (!optChip.selected) root.saveSetting(optRow.modelData.key, optChip.modelData.value)
                }
              }
            }
          }
        }
      }

      }

      Column {
        width: (column.width - column.spacing) / 2
        spacing: Style.space(12)

      // Network
      Section {
        title: "NETWORK  ·  " + (root.selectedIface || "total")
        BigGraph {
          values: root.netRxHist
          values2: root.netTxHist
          minimumScale: 10240
          lineColor: root.rxColor
          lineColor2: root.txColor
        }

        // Everything below uses fixed-width columns sized for the widest
        // possible value, so changing numbers never reflow the layout.
        FontMetrics {
          id: capFm
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
        TextMetrics { id: labelM; font: capFm.font; text: "Out ↑" }
        TextMetrics { id: rateM; font: capFm.font; text: "↓8888K" }
        TextMetrics { id: rateSM; font: capFm.font; text: "8888K/s" }
        TextMetrics { id: totalM; font: capFm.font; text: "↓888.88 MB" }

        // Legend: swatch, direction, current rate and peak over the window.
        // Always one line per direction.
        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: [
              { label: "In ↓", color: root.rxColor, now: root.netRxNow, hist: root.netRxHist },
              { label: "Out ↑", color: root.txColor, now: root.netTxNow, hist: root.netTxHist }
            ]

            Row {
              required property var modelData
              spacing: Style.space(6)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(10)
                height: Style.space(10)
                radius: width / 2
                color: modelData.color
              }

              Text {
                width: Math.ceil(labelM.advanceWidth)
                textFormat: Text.PlainText
                text: modelData.label
                color: root.bar.foreground
                font: capFm.font
              }

              Text {
                width: Math.ceil(rateSM.advanceWidth)
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: root.formatRate(modelData.now) + "/s"
                color: root.bar.foreground
                font: capFm.font
              }

              Text {
                textFormat: Text.PlainText
                text: "(peak " + root.formatRate(Math.max.apply(null, modelData.hist.concat([0]))) + "/s)"
                color: Qt.darker(root.bar.foreground, 1.3)
                font: capFm.font
              }
            }
          }
        }

        // Interface list: fixed height (scrolls when interfaces outnumber
        // the visible rows), so containers coming and going don't resize it.
        Flickable {
          id: ifList
          readonly property int visibleRows: 8
          readonly property real rowH: Math.ceil(capFm.height) + Style.space(6)
          width: parent.width
          height: visibleRows * rowH + (visibleRows - 1) * ifCol.spacing
          contentHeight: ifCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

        Column {
          id: ifCol
          width: ifList.width
          spacing: Style.space(2)

          Repeater {
            model: root.ifaceNames

            BorderSurface {
              id: ifRow
              required property string modelData
              readonly property var info: root.ifaceInfo(modelData)
              readonly property bool selected: root.selectedIface === modelData
              width: parent.width
              height: ifList.rowH
              radius: Style.spacing.labelGap
              color: selected ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
                : (ifHover.hovered ? Commons.Util.alpha(root.bar.foreground, 0.06) : "transparent")
              borderSpec: selected ? Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent) : Border.none()

              Text {
                id: ifName
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.right: ifRates.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: ifRow.info.name === ""
                  ? "Total (physical interfaces)"
                  : ifRow.info.name + (root.ips[ifRow.info.name] ? "  " + root.ips[ifRow.info.name] : "")
                color: ifRow.info.virtual ? Qt.darker(root.bar.foreground, 1.5) : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: ifRow.selected
                elide: Text.ElideRight
              }

              Row {
                id: ifRates
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Text {
                  width: Math.ceil(rateM.advanceWidth)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: "↓" + root.formatRate(ifRow.info.rx)
                  color: root.rxColor
                  font: capFm.font
                }

                Text {
                  width: Math.ceil(rateM.advanceWidth)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: "↑" + root.formatRate(ifRow.info.tx)
                  color: root.txColor
                  font: capFm.font
                }

                // Totals columns are reserved on every row (blank on the
                // Total row) so the rate columns line up and never move.
                Text {
                  width: Math.ceil(totalM.advanceWidth) + Style.space(10)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: ifRow.info.name !== "" ? "Σ ↓" + root.formatBytes(ifRow.info.rxTotal || 0) : ""
                  color: Qt.darker(root.bar.foreground, 1.3)
                  font: capFm.font
                }

                Text {
                  width: Math.ceil(totalM.advanceWidth)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: ifRow.info.name !== "" ? "↑" + root.formatBytes(ifRow.info.txTotal || 0) : ""
                  color: Qt.darker(root.bar.foreground, 1.3)
                  font: capFm.font
                }
              }

              HoverHandler { id: ifHover; cursorShape: Qt.PointingHandCursor }

              TapHandler {
                onTapped: root.selectedIface = ifRow.selected && ifRow.modelData !== "" ? "" : ifRow.modelData
              }
            }
          }
        }
        }
      }

      // Temperatures
      Section {
        title: "TEMPERATURE"

        Flow {
          width: parent.width
          spacing: Style.space(16)

          // An integrated GPU has no sensor of its own: it shares the CPU
          // die, so it reports the CPU package temperature.
          Repeater {
            model: [{ label: "CPU", value: root.temps.cpu, note: "" }]
              .concat(root.gpus.map(function(g) {
                var shared = g.temp <= 0 && g.memTotal <= 0
                return {
                  label: "GPU " + root.gpuShortName(g).replace(" (integrated)", ""),
                  value: shared ? root.temps.cpu : g.temp,
                  note: shared ? " (CPU package)" : ""
                }
              }))
              .concat([{ label: "NVMe", value: root.temps.nvme, note: "" }])

            Text {
              required property var modelData
              visible: modelData.value > 0
              textFormat: Text.PlainText
              text: modelData.label + "  " + modelData.value + "°C" + modelData.note
              color: root.tempColor(modelData.value)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      // Processes
      Section {
        title: "PROCESSES"

        Grid {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(16)
          rowSpacing: Style.space(10)

          Repeater {
            model: [
              { title: "CPU", mode: "cpu", list: root.topCpu },
              { title: "RAM", mode: "rss", list: root.topMem },
              { title: "GPU · " + root.gpuShortName(root.gpu), mode: "gpu", list: root.topGpuSel },
              { title: (root.gpu.memTotal > 0 ? "VRAM" : "GPU MEMORY") + " · " + root.gpuShortName(root.gpu), mode: "vram", list: root.topVramSel }
            ]

            Column {
              required property var modelData
              visible: root.hasGpu || (modelData.mode !== "gpu" && modelData.mode !== "vram")
              width: (parent.width - Style.space(16)) / 2
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: modelData.title
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              ProcList { width: parent.width; model: modelData.list; mode: modelData.mode }
            }
          }
        }
      }
      }
    }
  }
}

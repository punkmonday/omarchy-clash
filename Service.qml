import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Talks to the local mihomo (Clash Verge) REST API over its unix socket.
// Everything is a fixed local endpoint with `curl` timeouts and a response
// size cap in Model.js; nothing downloaded here is ever executed, and no
// dynamic value is interpolated into a shell — commands are passed as plain
// argv arrays. Periodic background polling is disclosed in the manifest and
// can be tuned or switched off through the widget's shell.json settings.
//
// The socket is found by probing, not stat-ing: candidates are tried in
// turn and the first one that answers is pinned until it fails to connect
// again (curl exit 7 covers both "no such file" and "core gone").
Item {
  id: root

  property var settings: ({})

  // Public state, all of it derived from API responses.
  property bool reachable: false
  property bool busy: false
  property string coreVersion: ""
  property string mode: "rule"
  property bool tunEnabled: false
  property int mixedPort: 0
  property var groups: []
  property int connectionsCount: 0
  property var topConnections: []
  property double downloadTotal: 0
  property double uploadTotal: 0
  property double downBps: 0
  property double upBps: 0
  property string dnsState: "unknown" // unknown | ok | empty | failed
  property int dnsAnswers: 0
  property string lastError: ""

  // The panel opens the sampler on demand; with the panel closed nothing
  // samples /connections at all.
  property bool trafficWanted: false
  readonly property bool shouldSample: trafficWanted

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 3, 3600)
  readonly property int speedSampleSec: intSetting("speedSampleSec", 2, 1, 60)
  readonly property bool dnsCheck: boolSetting("dnsCheck", true)
  readonly property string dnsProbeName: "www.gstatic.com"

  // Pinned socket: "" while probing candidates, set on the first success.
  property string socketPath: ""
  property string attemptedSocket: ""
  property string tickSocket: ""
  property string uid: ""

  // Speed sampling bookkeeping.
  property double _lastDown: 0
  property double _lastUp: 0
  property double _lastAt: 0
  property int _candidate: 0

  // Change signatures so a poll that finds nothing different does not rebuild
  // every delegate row in an open panel.
  property string _groupsSig: "[]"
  property string _topSig: "[]"

  // One action may be in flight; a later request replaces a still-queued one.
  property var _queuedAction: null
  property var _pendingAction: null

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || value === "true"
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function socketCandidates() {
    var override = String(setting("socketPath", "")).trim()
    if (override !== "") return [override]
    var list = []
    if (uid !== "") list.push("/run/clash-verge-service/users/" + uid + "/verge-mihomo.sock")
    list.push(Quickshell.env("HOME") + "/.local/share/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock")
    return list
  }

  // The pinned socket once found; otherwise one candidate per tick, rotating
  // each status refresh so a wedged core rotates instead of hammering one
  // path (curl exit 7 — missing file or dead socket — clears the pin).
  function currentSocket() {
    if (socketPath !== "") return socketPath
    if (tickSocket === "") {
      var list = socketCandidates()
      _candidate = (_candidate + 1) % list.length
      tickSocket = list[_candidate]
    }
    return tickSocket
  }

  function curlBase(timeoutSec) {
    attemptedSocket = currentSocket()
    return ["curl", "-sS", "--fail-with-body", "-m", String(timeoutSec),
      "--unix-socket", attemptedSocket]
  }

  function apiGet(process, path, timeoutSec) {
    if (process.running) return false
    process.command = curlBase(timeoutSec).concat(["-X", "GET", "http://localhost/" + path])
    process.running = true
    return true
  }

  function refreshStatus() {
    if (socketPath === "") tickSocket = ""
    var launched = false
    launched = apiGet(configsProcess, "configs", 3) || launched
    launched = apiGet(proxiesProcess, "proxies", 3) || launched
    launched = apiGet(versionProcess, "version", 3) || launched
    if (launched && !pollWatchdog.running) pollWatchdog.start()
  }

  function refreshConnections() {
    if (!shouldSample) return
    if (connectionsProcess.running) return
    connectionsProcess.command = curlBase(3).concat(["-X", "GET", "http://localhost/connections"])
    connectionsProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function refreshDns() {
    if (dnsProcess.running) return
    dnsProcess.command = curlBase(5).concat(["-X", "GET",
      "http://localhost/dns/query?name=" + dnsProbeName + "&type=A"])
    dnsProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function refreshNow() {
    refreshStatus()
    refreshConnections()
    if (dnsCheck) refreshDns()
  }

  function markUnavailable() {
    reachable = false
    coreVersion = ""
    tunEnabled = false
    mixedPort = 0
    publishGroups([])
    publishTop([])
    connectionsCount = 0
    downloadTotal = 0
    uploadTotal = 0
    downBps = 0
    upBps = 0
    dnsState = "unknown"
    dnsAnswers = 0
    _lastAt = 0
  }

  function publishGroups(next) {
    var sig = JSON.stringify(next)
    if (sig === _groupsSig) return
    _groupsSig = sig
    groups = next
  }

  function publishTop(next) {
    var sig = JSON.stringify(next)
    if (sig === _topSig) return
    _topSig = sig
    topConnections = next
  }

  function noteError(text) {
    lastError = Model.elide(String(text || "").trim(), 160) || "Request failed"
    errorClearTimer.restart()
  }

  // curl exit 7 (couldn't connect, including a missing socket file) unpins
  // the socket so the next tick tries the other candidate. Other failures
  // keep the pin and just surface the message.
  function handlePollFailure(exitCode, stderr, what) {
    if (exitCode === 7) {
      socketPath = ""
      markUnavailable()
      return
    }
    reachable = false
    noteError(stderr || (what + " request failed"))
  }

  // Sample-to-sample deltas, with the guards a counter needs: no sample yet,
  // a tiny gap, or a core restart rewinding the totals all zero the rate
  // instead of publishing a spike.
  function recordSpeeds(downloadTotalNow, uploadTotalNow) {
    var now = Date.now()
    var dt = (now - _lastAt) / 1000
    if (_lastAt === 0 || dt < 0.4 || downloadTotalNow < _lastDown || uploadTotalNow < _lastUp) {
      downBps = 0
      upBps = 0
    } else {
      downBps = (downloadTotalNow - _lastDown) / dt
      upBps = (uploadTotalNow - _lastUp) / dt
    }
    _lastDown = downloadTotalNow
    _lastUp = uploadTotalNow
    _lastAt = now
  }

  function runAction(method, path, body, onDone) {
    var command = { method: method, path: path, body: body, onDone: onDone || null }
    if (actionProcess.running) {
      _queuedAction = command
      return
    }
    launchAction(command)
  }

  function launchAction(command) {
    if (!command) return
    busy = true
    var argv = curlBase(5)
    var body = String(command.body || "")
    argv = argv.concat(["-X", command.method, "http://localhost/" + command.path])
    if (body !== "") argv = argv.concat(["-d", body])
    actionProcess.command = argv
    actionProcess.running = true
    _pendingAction = command
  }

  function setMode(next) {
    var value = String(next || "")
    if (Model.MODES.indexOf(value) === -1 || value === mode) return
    var previous = mode
    mode = value
    runAction("PUT", "configs", JSON.stringify({ mode: value }), function (ok) {
      if (!ok) { mode = previous; delayedRefresh.restart() }
    })
  }

  function toggleTun() {
    var next = !tunEnabled
    tunEnabled = next
    runAction("PUT", "configs", JSON.stringify({ tun: { enable: next } }), function (ok) {
      if (!ok) { tunEnabled = !next; delayedRefresh.restart() }
    })
  }

  function selectProxy(groupName, nodeName) {
    var group = String(groupName || "")
    var node = String(nodeName || "")
    if (group === "" || node === "") return
    var next = []
    var found = false
    for (var i = 0; i < groups.length; i++) {
      var item = groups[i]
      if (String(item.name) === group) {
        found = true
        if (String(item.now) === node) return
        next.push({ name: item.name, now: node, auto: item.auto, all: item.all })
      } else {
        next.push(item)
      }
    }
    if (!found) return
    publishGroups(next)
    runAction("PUT", "proxies/" + encodeURIComponent(group), JSON.stringify({ name: node }),
      function (ok) { if (!ok) delayedRefresh.restart() })
  }

  function flushFakeIp() {
    runAction("DELETE", "cache/fakeip/flush", "", function (ok) {
      if (ok) dnsState = "unknown"
      else delayedRefresh.restart()
    })
  }

  function openVerge() {
    Quickshell.execDetached(["clash-verge"])
  }

  Timer {
    id: statusTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: speedTimer
    interval: root.speedSampleSec * 1000
    repeat: true
    running: root.shouldSample
    triggeredOnStart: true
    onTriggered: root.refreshConnections()
  }

  Timer {
    id: dnsTimer
    interval: 60000
    repeat: true
    running: root.dnsCheck
    triggeredOnStart: true
    onTriggered: root.refreshDns()
  }

  Timer {
    // A fresh boot usually starts the shell before Clash Verge's service has
    // spawned the core; poll quickly until it answers, then fall back to the
    // normal cadence.
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.reachable || ticks >= 15) startupRamp.running = false
      else root.refreshStatus()
    }
  }

  Timer {
    id: delayedRefresh
    interval: 700
    onTriggered: root.refreshStatus()
  }

  Timer {
    // A curl wedged on a dead socket would skip every later poll on its
    // `running` guard; reap anything past its own timeout.
    id: pollWatchdog
    interval: 10000
    onTriggered: {
      if (configsProcess.running) configsProcess.running = false
      if (proxiesProcess.running) proxiesProcess.running = false
      if (connectionsProcess.running) connectionsProcess.running = false
      if (versionProcess.running) versionProcess.running = false
      if (dnsProcess.running) dnsProcess.running = false
      if (actionProcess.running) actionProcess.running = false
    }
  }

  Timer {
    id: errorClearTimer
    interval: 5000
    onTriggered: root.lastError = ""
  }

  Process {
    id: uidProcess
    command: ["id", "-u"]
    running: true
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.uid = String(stdout.text || "").trim()
    }
  }

  Process {
    id: configsProcess
    running: false
    command: []
    stdout: StdioCollector { id: configsStdout; waitForEnd: true }
    stderr: StdioCollector { id: configsStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var text = String(configsStdout.text || "")
      if (exitCode !== 0) {
        root.handlePollFailure(exitCode, String(configsStderr.text || ""), "configs")
        return
      }
      var parsed = Model.parseConfigs(text)
      if (!parsed) {
        root.reachable = false
        root.noteError("Unexpected response from the mihomo API")
        return
      }
      root.socketPath = root.attemptedSocket
      root.reachable = true
      root.mode = parsed.mode
      root.mixedPort = parsed.mixedPort
      // Do not fight an optimistic toggle that the core has not caught up to
      // yet; only follow the read-back once the action settles.
      if (!root.busy) root.tunEnabled = parsed.tun
      root.lastError = ""
    }
  }

  Process {
    id: proxiesProcess
    running: false
    command: []
    stdout: StdioCollector { id: proxiesStdout; waitForEnd: true }
    stderr: StdioCollector { id: proxiesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (exitCode === 7) root.socketPath = ""
        return
      }
      var parsed = Model.parseProxies(String(proxiesStdout.text || ""))
      if (parsed) root.publishGroups(parsed)
    }
  }

  Process {
    id: connectionsProcess
    running: false
    command: []
    stdout: StdioCollector { id: connectionsStdout; waitForEnd: true }
    stderr: StdioCollector { id: connectionsStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.downBps = 0
        root.upBps = 0
        root._lastAt = 0
        if (exitCode === 7) {
          root.socketPath = ""
          if (!configsProcess.running) root.markUnavailable()
        }
        return
      }
      var parsed = Model.parseConnections(String(connectionsStdout.text || ""))
      if (!parsed) return
      root.socketPath = root.attemptedSocket
      root.reachable = true
      root.downloadTotal = parsed.downloadTotal
      root.uploadTotal = parsed.uploadTotal
      root.connectionsCount = parsed.count
      root.publishTop(parsed.top)
      root.recordSpeeds(parsed.downloadTotal, parsed.uploadTotal)
    }
  }

  Process {
    id: versionProcess
    running: false
    command: []
    stdout: StdioCollector { id: versionStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var parsed = Model.parseVersion(String(versionStdout.text || ""))
      if (parsed) root.coreVersion = parsed
    }
  }

  Process {
    id: dnsProcess
    running: false
    command: []
    stdout: StdioCollector { id: dnsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.dnsState = "failed"
        root.dnsAnswers = 0
        return
      }
      var parsed = Model.parseDns(String(dnsStdout.text || ""))
      root.dnsState = parsed.state
      root.dnsAnswers = parsed.answers
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var done = root._pendingAction
      root._pendingAction = null
      root.busy = false
      var ok = exitCode === 0
      if (ok) {
        if (exitCode === 0 && root.attemptedSocket !== "") root.socketPath = root.attemptedSocket
        root.lastError = ""
      } else {
        if (exitCode === 7) root.socketPath = ""
        var detail = String(actionStdout.text || "") || String(actionStderr.text || "")
        root.noteError(detail || "Request failed")
      }
      if (done && done.onDone) done.onDone(ok)
      // A queued request replaces the previous one; either way the state the
      // optimistic update painted must be verified against the core.
      if (root._queuedAction) {
        var next = root._queuedAction
        root._queuedAction = null
        Qt.callLater(function() { root.launchAction(next) })
      } else if (ok) {
        delayedRefresh.restart()
      }
    }
  }
}

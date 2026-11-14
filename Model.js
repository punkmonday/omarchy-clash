// Pure parsing helpers for mihomo REST API responses. Everything the core
// returns is untrusted data — proxy names and hosts can carry markup-shaped or
// absurdly long strings — so every field is type-checked, length-capped, and
// total response size is limited before anything reaches the UI.

var MAX_RESPONSE_BYTES = 2 * 1024 * 1024
var MAX_GROUPS = 48
var MAX_NODES = 256
var MAX_TOP_CONNECTIONS = 8
var MAX_SCAN = 512
var MAX_NAME = 90

function parse(raw) {
  var text = String(raw || "").trim()
  if (text === "" || text.length > MAX_RESPONSE_BYTES) return null
  try {
    var data = JSON.parse(text)
    return data && typeof data === "object" ? data : null
  } catch (e) {
    return null
  }
}

function elide(text, max) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > max ? value.substring(0, max - 1) + "…" : value
}

function count(value) {
  return typeof value === "number" && isFinite(value) && value >= 0 ? value : 0
}

function parseVersion(raw) {
  var data = parse(raw)
  if (!data) return null
  return elide(data.version, 32)
}

var MODES = ["rule", "global", "direct"]

function parseConfigs(raw) {
  var data = parse(raw)
  if (!data) return null
  var mode = MODES.indexOf(String(data.mode)) !== -1 ? String(data.mode) : "rule"
  return {
    mode: mode,
    tun: !!(data.tun && data.tun.enable === true),
    mixedPort: typeof data["mixed-port"] === "number" ? data["mixed-port"] : 0
  }
}

// Only groups the user can actually pick: Selector-style pools. Built-in
// pseudo proxies (Direct, Reject, …) carry no `all` list and fall out here.
var SELECTOR_TYPES = ["Selector", "URLTest", "Fallback", "LoadBalance"]

function parseProxies(raw) {
  var data = parse(raw)
  if (!data || !data.proxies || typeof data.proxies !== "object") return null
  var groups = []
  for (var key in data.proxies) {
    if (groups.length >= MAX_GROUPS) break
    var proxy = data.proxies[key]
    if (!proxy || typeof proxy !== "object") continue
    if (SELECTOR_TYPES.indexOf(String(proxy.type)) === -1) continue
    if (!Array.isArray(proxy.all) || proxy.all.length === 0) continue
    var all = []
    for (var i = 0; i < proxy.all.length && all.length < MAX_NODES; i++) {
      var node = elide(proxy.all[i], MAX_NAME)
      if (node !== "") all.push(node)
    }
    if (all.length === 0) continue
    groups.push({
      name: elide(key, MAX_NAME),
      now: elide(proxy.now, MAX_NAME),
      auto: String(proxy.type) === "URLTest",
      all: all
    })
  }
  groups.sort(function (a, b) { return String(a.name).localeCompare(String(b.name)) })
  return groups
}

// Picked out of a live connection row: who it talks to and which proxy chain
// carries it. Hostnames come from the network, so all strings are elided.
function connectionRow(conn) {
  var meta = (conn && conn.metadata) || {}
  var host = elide(meta.host || meta.destinationIP || "?", MAX_NAME)
  var port = elide(meta.destinationPort, 8)
  var chains = Array.isArray(conn && conn.chains) ? conn.chains : []
  var proxy = chains.length > 0 ? elide(chains[chains.length - 1], MAX_NAME) : ""
  return { host: host, port: port, proxy: proxy, down: count(conn && conn.download) }
}

function parseConnections(raw) {
  var data = parse(raw)
  if (!data) return null
  var conns = Array.isArray(data.connections) ? data.connections : []
  var rows = []
  for (var i = 0; i < conns.length && i < MAX_SCAN; i++) {
    if (conns[i] && typeof conns[i] === "object") rows.push(connectionRow(conns[i]))
  }
  rows.sort(function (a, b) { return b.down - a.down })
  return {
    downloadTotal: count(data.downloadTotal),
    uploadTotal: count(data.uploadTotal),
    count: conns.length,
    top: rows.slice(0, MAX_TOP_CONNECTIONS)
  }
}

function parseDns(raw) {
  var data = parse(raw)
  if (!data) return { state: "failed", answers: 0 }
  var answers = Array.isArray(data.Answer) ? data.Answer : []
  return { state: answers.length > 0 ? "ok" : "empty", answers: Math.min(answers.length, 32) }
}

// Bytes/split into an integer value plus a unit suffix, in SI units (network
// convention). Units stay literal: they are not translated words.
var BYTE_UNITS = ["B/s", "KB/s", "MB/s", "GB/s"]
var TOTAL_UNITS = ["B", "KB", "MB", "GB", "TB"]

function scaled(value, units) {
  var size = count(value)
  var index = 0
  while (size >= 1000 && index < units.length - 1) {
    size /= 1000
    index += 1
  }
  return { value: size, digits: size >= 100 || index === 0 ? 0 : 1, unit: units[index] }
}

function rate(value) {
  return scaled(value, BYTE_UNITS)
}

function bytes(value) {
  return scaled(value, TOTAL_UNITS)
}

if (typeof module !== "undefined") {
  module.exports = {
    MODES: MODES,
    parseVersion: parseVersion,
    parseConfigs: parseConfigs,
    parseProxies: parseProxies,
    parseConnections: parseConnections,
    parseDns: parseDns,
    rate: rate,
    bytes: bytes,
    elide: elide
  }
}

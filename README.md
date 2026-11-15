# punkmonday.clash — Clash Verge status for the Omarchy bar

![Bar preview](preview.png)

A shell plugin (not a fork of a built-in) that watches the local mihomo
core used by Clash Verge Rev and lets you drive it without leaving the bar.

## What it shows

- **Bar icon** — a fine wireframe globe (matched to the weight of the other
  bar glyphs) that dims when the core is offline and half-dims when TUN is
  off. Single icon slot, no text.
- **Panel** (left click) — Mihomo version, current mode, TUN switch, every
  selectable proxy group, live down/up speeds, session totals, active
  connection count with the top talkers, and a fake-IP DNS health probe.
- **Tools** — flush the fake-IP cache, open Clash Verge, force a refresh.

The DNS probe asks mihomo's *own* resolver (over the API) for
`www.gstatic.com`. When the fake-IP pipeline is broken you see it here as
"No answers" instead of as a silent "limited connectivity" network badge.

## Controls

| Input | Action |
|---|---|
| Left click icon | Open the panel |
| Right click icon | Toggle TUN |
| Middle click icon | Refresh now |
| `Up/Down` (or `j/k`) in panel | Move the cursor across TUN → mode → groups → tools |
| `Left/Right` on the mode row | Cycle Rule / Global / Direct |
| `Enter/Space` | Activate (opens group popups) |
| `t` / `r` / `1` `2` `3` | Toggle TUN / refresh / pick mode |
| `Esc` | Close (or close an open group popup first) |

## How it talks to the core

Only over Clash Verge's local mihomo unix socket with `curl`:

1. primary: `/run/clash-verge-service/users/<uid>/verge-mihomo.sock`
2. fallback: `~/.local/share/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock`
3. override: set `socketPath` in the widget's `shell.json` entry.

Mode and TUN are changed with `PUT /configs`, group selection with
`PUT /proxies/<group>`, and the fake-IP cache with
`DELETE /cache/fakeip/flush`. There is no external network use; responses
are size-capped and every displayed string is rendered as plain text.

## Settings (inline in `~/.config/omarchy/shell.json`)

```jsonc
{ "id": "punkmonday.clash",
  "refreshIntervalSec": 10,  // mode/TUN/groups poll
  "speedSampleSec": 2,       // byte-totals sample while the panel is open
  "dnsCheck": true,          // 60 s DNS health probe
  "socketPath": "" }         // optional API socket override
```

## Files

- `manifest.json` — plugin contract (`bar-widget`, settings schema)
- `Panel.qml` — bar button + keyboard panel
- `Service.qml` — polling engine and write actions
- `Model.js` — capped/sanitized parsers
- `ClashText.qml` — local plain-text `Text` for all dynamic strings
- `i18n/en.json` — string catalog (other languages fall back to this)

## Requirements

- Omarchy (the `omarchy-shell` Quickshell process)
- Clash Verge Rev running its mihomo core with the local API unix socket
  enabled (the Clash Verge service default)
- `curl` on PATH for the socket calls

## Install

```sh
omarchy plugin add https://github.com/punkmonday/omarchy-clash.git --enable
```

Or enable a copy you already have with
`omarchy plugin enable punkmonday.clash --section right`.

## Remove

```sh
omarchy plugin remove punkmonday.clash
```

This disables the widget (removing it from the bar layout in `shell.json`)
and deletes the git checkout; nothing else on the system is touched, and
the plugin writes no user configuration beyond that layout entry when you
enable it.

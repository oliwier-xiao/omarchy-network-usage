# Network Usage

Which apps used your bandwidth, one click from your Omarchy bar.

![The Network Usage panel: today's download and upload, ranked by app](preview.png)

Two ranked bar charts — one for what came down, one for what went up — and a day of history
behind them. When a gigabyte went somewhere this afternoon, this is the thing that says where.

Measured at packet level rather than inferred from open sockets, so **UDP counts** — which today
means QUIC, which means most of what a browser does. Traffic from a **container** arrives under
the container's name instead of a hole in the numbers, which matters on the day a local build
pulled a few gigabytes and nothing on the machine will say what did.

An Omarchy **Quattro** shell plugin (`bar-widget` + `service`). Needs `omarchy-shell` and the
`nethogs` package from the standard repositories. No sudo or pkexec is required — nethogs grants
its own binary the capabilities it needs when it installs, and the plugin never asks for more.

---

## Install

**1. Install `nethogs`.** Nothing else on a stock Arch box attributes wire bytes to a process, so
the plugin has nothing to count without it — the kernel does not keep that score per app.

```bash
omarchy pkg add nethogs
```

No sudo or pkexec is needed afterwards: the package grants its own binary the capabilities it
needs at install time, and the plugin never asks for more.

**2. Add the plugin.**

```bash
omarchy plugin add https://github.com/oliwier-xiao/omarchy-network-usage.git --enable
```

If the bar does not pick it up:

```bash
omarchy restart shell
```

The panel will tell you if `nethogs` is not there yet. To ask directly:

```bash
~/.config/omarchy/plugins/oliwier.network-usage/bin/net-usage doctor
```

---

## What the numbers mean

**Wire bytes**, headers included, which run about 3% above the payload an app thinks it moved.
That is the honest figure — it is what your connection actually carried and what a data cap
counts.

Totals are counted continuously between samples, not sampled from them, so a shorter sample
interval does not make them more accurate. It only makes the panel newer.

## What nothing on this machine asked for

A shared network carries every host's broadcast and multicast chatter — mDNS, NetBIOS, SSDP — to
every card attached to it. Your machine receives that traffic because it is addressed to everyone,
no socket here owns a single byte of it, and the kernel discards it on arrival. It is not a
download. Nothing requested it and nothing read it.

Packet-level accounting still counts it, and since it belongs to no process it can only ever be
drawn as one enormous unnamed bar. On a busy office network it is routinely most of the inbound
total for the day — a couple of kilobytes a second, every second, which is a few hundred megabytes
by midnight. The charts leave it out, so what you see is what this machine actually used.

To see what it consists of on your network:

```
~/.config/omarchy/plugins/oliwier.network-usage/bin/net-usage explain
```

Six pcap filters run over one shared window, so the shares are comparable:

```
ARRIVING ON THE WIRE                   DOWN  SHARE
everything                          10.7 KB   100%
not addressed to this host           9.2 KB    86%
  mDNS / Bonjour (5353)              5.9 KB    54%
  NetBIOS (137, 138)                 3.9 KB    36%
  SSDP / UPnP (1900)                    0 B     0%
QUIC (udp 443)                          0 B     0%
```

**Count broadcast traffic nothing asked for** puts it back in, for measuring the wire rather than
the machine.

Version 1.0.0 counted it. Upgrading drops the one row it was recorded under, once, and brings the
affected day totals down with it — the real bytes in that row cannot be told apart from the noise
after the fact, and leaving it in would mean charts that promise to exclude that traffic while
still drawing it.

## The two unknown rows

What is left over after that genuinely cannot be traced from user space, and it gets its own row
per protocol rather than one shared lump, because the two have different causes.

**(unknown TCP)** is almost always a container. A socket living in another network namespace has
no process on this side of it. With **Name container traffic** on, most of it is pulled back out
and named, so this row is usually small.

**(unknown UDP)** is a connectionless socket that closed before it could be matched to a process,
or QUIC that arrived faster than the mapping could keep up.

If either is ever the largest bar, that is worth knowing rather than worth hiding.

## Two charts, not one

Download and upload are different questions asked of the same list, and you almost always have
one of them in mind. Side by side in one chart, the answer to either is harder to find. Apart,
each chart ranks independently — the app that dominates your download often is not the one
dominating your upload, and two charts show that at a glance where one would bury it.

It also means colour is decoration here rather than the thing carrying the meaning, so nothing
is lost if the two hues read the same to you.

---

## Settings

| Setting | Default | What it does |
|---|---|---|
| Next to the bar icon | Download | `Download`, `Both directions`, or `Nothing`. Both roughly doubles the width. |
| Apps per chart | 8 | Bars drawn before the rest are summed into one row. Click that row, or press `e`, to list them all. |
| Name container traffic | on | Reads each container's own byte counters and puts a name on them. |
| Show what could not be attributed | on | Keeps the chart honest about the size of the gap. |
| Count broadcast traffic nothing asked for | off | Adds back the chatter no socket here owns. |
| Sample every | 2s | A battery setting, not an accuracy one. |
| Keep history for | 90 days | Older days are dropped when the file is next written. |
| Watch this interface | empty | Empty follows the default route. Name one when a tunnel is up. |

Set them from the bar's widget settings, or:

```bash
omarchy bar set oliwier.network-usage topApps 10
omarchy bar move oliwier.network-usage --section right
```

## Keys

| Key | Does |
|---|---|
| `↑`, `↓` | Scroll the panel |
| `e` | List every app, or fold the tail back up |
| `d` | Step through the last seven days |
| `t` | Back to today |
| `Tab` | Next panel |
| `Esc` | Close |

![The day strip and key hints along the bottom of the panel](docs/history.png)

Clicking a day in the footer strip pins it; clicking today unpins.

The last row of each chart sums whatever did not fit — click it to list every app instead, and
**show fewer** to fold it back. Expanded charts are usually taller than the panel, which is what
the scrolling is for.

## From a terminal

The collector is a plain script and is useful on its own. This is the answer to "what is
using my connection right now":

```bash
~/.config/omarchy/plugins/oliwier.network-usage/bin/net-usage top
```

```
APP                              DOWN           UP  SOURCE
curl                           3.9 MB      76.4 KB  proc
webae-postgres                 2.9 MB      79.1 KB  container
claude                         4.9 KB      65.9 KB  proc
(unknown TCP)                  1.2 KB          0 B  unattributed
```

`net-usage top [rows] [seconds]` watches for a few seconds and ranks what moved.
`net-usage explain [seconds]` breaks the inbound traffic down by pcap filter, which is how you
find out what an unnamed bar was made of. `net-usage doctor` reports what is missing.
`net-usage probe` prints the interface, the date and the container counters once.

## What it cannot tell you

- **A recycled process id** is attributed to whatever held that id before it, until the daily
  restart clears the slate. There is no way to see this from outside the tool.
- **A tunnel counts once.** With WireGuard or a VPN up, the same payload is visible as plaintext
  inside the tunnel and as encrypted UDP outside it. The plugin follows the default route and
  counts one of them; name the other under **Watch this interface** if it is the one you meant.
- **Traffic before the shell started** was not counted. This is a ledger kept from when it was
  opened, not a reconstruction.

---

## Removing it

```bash
omarchy plugin remove oliwier.network-usage
```

That leaves the history behind. To take that too:

```bash
rm -rf ~/.local/state/omarchy/network-usage
```

## Where things live

| Path | What |
|---|---|
| `~/.config/omarchy/plugins/oliwier.network-usage/` | The plugin |
| `~/.local/state/omarchy/network-usage/history.json` | Per-day, per-app totals |
| `~/.config/omarchy/shell.json` | Where the bar records your settings |

The history file is state, not config — numbers the machine produced rather than preferences you
set. If it is ever unreadable it is moved aside once as `history.json.broken` and counting starts
again, rather than the day being lost to a parse error.

The shell never opens it. `omarchy-shell` is one process for every plugin on the desktop, so the
file is opened once in a child process, with the flags that refuse a symlink outright and decline
to wait on a pipe, and its type, its owner and its length are then read off that one descriptor
rather than off the name — which anything else running as you can change between one look and the
next. Something too large is refused whole rather than cut down to the ceiling: half a document is
not a shorter history, it is a parse error wearing one.

Nor is it written by the shell. The replacement is built beside it under a name that the open
either creates or fails on, and then renamed over the old one — so a link left at `history.json`
is what gets replaced, and whatever it pointed at is never opened.

## License

MIT — see [LICENSE](LICENSE).

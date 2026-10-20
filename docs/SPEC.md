---
created: 2026-10-20
status: living
tags: [harbour, spec, macos, swift, menubar, cli, dev-servers, ports]
source: "Design conversation, 2026-10-20: losing track of locally hosted html/vite/rust frontends across tmux, Claude Code sessions and closed terminals"
purpose: The v1 contract for Harbour — what it shows, what it kills, what it stores, and what it deliberately doesn't do
---

# Harbour — v1 spec

Harbour is a macOS menu bar app and CLI that shows every local dev server you have running: which project it belongs to, its port, its memory and its uptime. You can open a server or kill it, together with the rest of that project's process tree. It derives everything from live OS state, so it has no catalogue to go stale. The only things it stores are your pins and name overrides.

---

## Why it exists

Local web apps have become desktop apps without any of the infrastructure desktop apps get. A pinned browser tab is the window, a port number is the app's identity, and a server process started from some shell is the app. Here is what a desktop app has and a local web app lacks:

| Desktop app | Local web app (before Harbour) |
|---|---|
| bundle id as identity | an arbitrary port number |
| running dot in the Dock | nothing |
| Quit | find the terminal that started it, if it still exists |
| single instance enforced | two servers silently share 5193 (one on IPv4, one on IPv6) |

Harbour v1 is **the Dock for local web apps**. The OS knows sockets and processes but not projects. Harbour's whole job is the join: socket → process tree → working directory → project → page title.

The state of the author's laptop on 2026-10-20 was the motivating evidence. There were seven orphaned `python -m http.server` processes, 14–41 days old with parent pid 1, which `lsof` lists only as `Python`. Port 5193 was double-bound by two unrelated projects. Four servers were bound to `*`, which serves their folders to the whole wifi network.

## Principles

- **Derived, not stored.** Everything about what is running is read fresh from the OS on every refresh. The only stored data is what you created on purpose, namely pins and name overrides. Port assignment is a function of the project's path, not a registry entry. *Rationale:* a stored fact stays true only if the event that changes it also forces its update, and nothing forces a port registry to update when a process dies.
- **Light on the system.** Process data is read through `libproc` and `sysctl`, never by shelling out to `lsof` or `ps`, which take hundreds of milliseconds per call. Refresh every 2 s while the menu is open and every 30 s otherwise.
- **Kill errs toward too little.** If Harbour can't tell where a project's process tree begins, it kills less, never more.
- **GUI and CLI share one core.** The menu is for the human and the CLI is for agents. Neither can do something the other's data can't support.

## What counts as a server

A **listener** is a TCP socket in LISTEN state owned by a process Harbour can inspect, which means one with the same uid.

A **server** is one listening process, together with all the ports it holds.

A **project** is the git root of the server's working directory, or the working directory itself if there's no git root. Servers in the same project are grouped together. A typical example is a vite frontend plus a Rust backend.

**Sections:**
- **Projects** holds servers whose working directory is under a configured root (default `~/code`, `~/research`). This section is the default view.
- **System** holds everything else, such as AirPlay, rapportd, Discord, Postgres and the Figma agent. It's collapsed by default, and Harbour never offers to reap anything in it.

## Naming

Each server gets the first name available from this list:
1. A user override from the config file, keyed by project path and port.
2. The HTML `<title>` from `GET /` on the port. The request has a 500 ms timeout and is cached per process; it is re-fetched when the pid or the process start time changes.
3. The listening binary's own name, unless it's an interpreter or package runner (`python`, `node`, `bun`, `uv`, `npm`, …). For example `api-server` or `render-worker`, which say more than the folder's manifest does.
4. The manifest name in the working directory (`package.json` `name`, or `Cargo.toml` `[package] name`).
5. The project folder name, plus the subpath when the server runs below the git root (`myapp › gui/mockups`).

A successful title fetch also marks the server as **HTTP**. Clicking a non-HTTP server's row doesn't open a browser.

## The process tree and kill

The **tree root** is found by walking up from the listening process through its parents. The walk stops *below* the first parent that is any of:
- pid 1 (launchd)
- an **interactive** shell (`zsh`, `bash`, `sh`, `fish`, `dash`, `login` with no `-c` and no script argument). Command shells (`sh -c …`, `bash script.sh`) are transparent, so the walk climbs through them. *Rationale:* `just` and `npm` run every recipe line through `sh -c`. If those shells stopped the walk, the runner that started the frontend and backend together would be left out of the tree.
- a multiplexer or terminal: `tmux`, `screen`, `ghostty`, `Terminal`, `iTerm2`, `sshd`
- any executable under `/Applications/` or inside a `.app/Contents/` bundle. This catches Claude.app's `disclaimer` helper and Claude Code's own `claude.app` binary, which spawn servers started from Claude sessions.
- another server, meaning a process that itself holds a listener. *Rationale:* on 2026-10-20 a Python hub on :5197 had spawned `just → bash → render-worker` (:8787). Killing the worker must not reach the hub.

So `just dev → sh -c → vite → esbuild` has its root at `just`.

Killing a **project** kills every server tree in it. This is what "kill the frontend and the backend" means when they were started separately.

**The tree** is the root plus all its descendants.

**Kill** sends SIGTERM to every pid in the tree, waits 3 s, then sends SIGKILL to any survivors. The CLI and the app use the same function.

**Memory** is the sum of `ri_phys_footprint` (`proc_pid_rusage`) over the tree. That is the number Activity Monitor reports. RSS underreports on macOS because of memory compression: vite showed 11 MB RSS.

## Badges

Badges are warnings only. Harbour never acts on its own.

- **Orphan:** the tree root's parent is launchd *and* the root is not a launchd job. Whether a pid is a launchd job is checked once per (pid, start time) against `launchctl list`. *Rationale:* LaunchAgents, such as your own background services or Homebrew's Postgres, also have ppid 1, and they're supposed to.
- **Exposed:** at least one socket is bound to a wildcard address (`0.0.0.0` / `::`) rather than loopback.
- **Double-bound:** another process holds the same port number on the other address family. Which one `localhost:<port>` reaches depends on whether the browser tries IPv4 or IPv6 first.

The menu bar icon shows a count only when a Projects server has a badge. It never shows a running total.

## The menu

The menu is a `MenuBarExtra` in window style.

- **Size:** 400 pt wide in every state. The height fits the content, up to 860 pt (always leaving 120 pt of the screen's usable height free), and scrolls beyond that. *Rationale:* left to itself, a ScrollView in a `MenuBarExtra` sizes to its ideal height rather than its content, and `DisclosureGroup` widened the menu when it opened (2026-10-20).
- **Order:** a total order, so rows never move between refreshes. Rows sort by what you see: a project group by its header, a lone server by its name. Ties break on port, then pid. *Rationale:* on 2026-10-20 the two servers sharing 5193 tied on port and swapped places on every scan.
- **Row:** name, port(s), memory and badges. Pin and kill sit in fixed-width slots so that hovering never shifts the layout. Clicking the row opens `http://localhost:<port>` (HTTP servers only). On hover, the row shows a kill button and a pin toggle.
- **Project header:** shown only when a project has more than one server. It has its own "kill all".
- **Detail**, expanded inline from the row: uptime, full command line, working directory, the process tree with per-pid memory and a kill button on each node, bind addresses, and the tmux location (`session:window.pane`) when an ancestor is a tmux pane's shell. **Jump to pane** switches an attached tmux client to that pane, or opens Ghostty with `tmux attach -t <target>` if no client is attached.
- **Pinned but not running:** the row stays in place, greyed out with "stopped", and keeps its working directory. If that folder no longer exists, the row says so. Version 1 has no Start button.
- **Footer:** "Reap orphans (n)", which kills every orphaned Projects tree after a confirmation listing them. Also the System disclosure, Launch at login, and Quit.

## CLI

The CLI is `harbour`, installed to `~/.local/bin`.

```
harbour ls [--all] [--json]     # Projects (or everything) with port, pid, memory, uptime, badges
harbour kill <port|name>        # kill that server's tree; a project name kills the whole project
harbour port [label]            # the derived port for this project (+ label), e.g. `harbour port api`
```

`harbour port` hashes the git root path, relative to `$HOME`, plus the optional label into 20000–29999. If that port is held by another project, it tries the next one. If the port is already held by this project, it still prints it, and notes on stderr that it's in use. The range avoids common framework defaults (3000, 5173, 8000, 8080) and macOS's ephemeral range (49152+). No assignment is written anywhere.

A single line in the global CLAUDE.md points agents at the CLI: before binding a port, run `harbour port`; to see what's running, run `harbour ls`.

## Storage

All stored state lives in one file, `~/.config/harbour/config.json`, readable by humans and agents:

```json
{
  "roots": ["~/code", "~/research"],
  "names": { "~/code/myapp:5193": "Myapp mockups" },
  "pins":  [{ "project": "~/code/myapp", "cwd": "~/code/myapp/web", "port": 5173, "command": "node node_modules/vite/bin/vite.js --port 5173" }]
}
```

## Build

- Swift 6.3, SwiftUI with `@Observable`, macOS 26 deployment target. The app isn't sandboxed, because it has to inspect and signal other processes.
- A Swift package with three targets: `HarbourCore` (library), `harbour` (CLI) and `HarbourApp` (menu bar app). A script bundles `HarbourApp` into `Harbour.app` (with `LSUIElement`, ad-hoc signed) in `~/Applications`, and links the CLI into `~/.local/bin`.

## Not in v1

- **Starting or restarting pinned servers.** Pins record the command so this can be added later, but v1 only observes and kills.
- **`*.localhost` names behind a local proxy.** Using the port as identity is the remaining bandaid: pinned tabs bookmark an implementation detail. Names would make ports invisible and collisions irrelevant. Derived ports deliver most of that value until then.
- **Remote hosts** (a home server or a VPS). The server model carries a `host` field so a Tailscale + `ss` source can be added later without reshaping anything.
- **Auto-reaping.** Harbour flags orphans and only reaps them when asked.

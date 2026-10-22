# Harbour

A macOS menu bar app and CLI that shows every local dev server you have running: which project it belongs to, its port, its memory and its uptime. Click a row to open it, or kill a server together with the rest of its project's process tree.

Local web apps have become desktop apps without any of the infrastructure desktop apps get. A pinned browser tab is the window and a port number is the app's identity. The server is whatever process some long-closed terminal or agent session left running. Harbour is the Dock for that class of app.

## What it shows

- **Rows** grouped by project (git root): the name, port(s), memory (physical footprint for the whole process tree) and uptime.
- **Names** come from the page's `<title>`, then the binary's name, then `package.json` / `Cargo.toml`, then the folder.
- **Badges:**
  - 🌙 **orphan:** whatever started the server is gone (a closed terminal or agent session), but it's still running.
  - ⧉ **double-bound:** another process holds the same port on the other IP family, so which one `localhost:<port>` reaches depends on the browser.
  - 📶 **exposed:** bound to all interfaces, so reachable from your network. (`python -m http.server` does this unless you pass `--bind 127.0.0.1`.)
- **Detail:** the command line, folder, bind addresses, the process tree with a kill button per process, and the tmux pane the server is running in, with a "jump to pane" button.
- **Pins** keep a server's row in the list, greyed out, after it stops. Click a stopped pin to start it again: Harbour types the command that started the whole process tree (`./dev.sh`, `npm run dev`) into its own window of a detached tmux session called `harbour`, then opens the page once it answers. The window's shell outlives the server, so if a start fails, its output is still in the pane, which "show pane" opens. The command is saved in the config as a plain shell line, so you can change it (to `just dev`, say).
- **Hotkey and filter:** <kbd>⌃⌥P</kbd> opens the menu from anywhere, with the cursor in a filter field. Type a name, folder or port, then press Return to open the first match, or to start the first matching stopped pin if nothing running matches. Esc clears the field.
- **Memory history:** a sparkline in the detail view of the process tree's footprint over the last two hours, for spotting a dev server that leaks.
- **Open the folder** in your editor (`nvim` runs in your terminal; Zed, Cursor or VS Code open as apps) or in a new terminal window.

Everything is read live through `libproc`. Harbour never shells out to `lsof` and keeps no registry that could go stale. The only stored state is your pins and name overrides, in `~/.config/harbour/config.json`.

## CLI

```
harbour ls [--all] [--json]   # what's running (projects, or everything)
harbour kill <port|name>      # kill a server's process tree; a project name kills the whole project
harbour port [label]          # this project's stable port, e.g. `harbour port api`
```

`harbour port` hashes the git root (plus an optional label) into 20000–29999 and skips to the next port if that one is taken. The same project always gets the same port, and nothing is written anywhere. It's meant for coding agents: one line in your agent instructions ("take dev-server ports from `harbour port`") stops them from all reaching for 5173.

## Install

Requires macOS 26 and Swift 6.2 or later (Xcode 26).

```bash
./scripts/install.sh
```

The script builds a release, installs `Harbour.app` to `~/Applications` and the CLI to `~/.local/bin/harbour`, then launches the app. If `just` is installed, `just install`, `just dev` and `just test` work too.

Settings live in `~/.config/harbour/config.json`, and every key is optional:

```json
{
  "roots": ["~/projects"],
  "hotkey": "ctrl+option+p",
  "editor": "nvim",
  "terminal": "Ghostty"
}
```

- **`roots`:** servers whose working directory is under one of these count as projects. Everything else goes in a collapsed System section.
- **`hotkey`:** use `"off"` to disable it.
- **`editor` and `terminal`:** auto-detected when unset.

## Design

[docs/SPEC.md](docs/SPEC.md) is the v1 contract: how a process tree's root is found, what "kill" reaches, how orphans are told apart from launchd services, and what was deliberately left out.

---
title: Nehir IPC & CLI Reference
---

# Nehir IPC & CLI Reference

This document covers the Nehir automation surface. For the docs hub, see [Documentation Home](index.md). For internal architecture, see [ARCHITECTURE.md](ARCHITECTURE.md). For contribution process, see the [Contribution Guide](CONTRIBUTING.md).

## Table of Contents

- [Architecture](#architecture)
- [Installation](#installation)
- [IPC Protocol](#ipc-protocol)
  - [Socket & Authorization](#socket--authorization)
  - [Wire Format](#wire-format)
  - [Security Model](#security-model)
- [CLI Reference](#cli-reference)
  - [Top-Level Commands](#top-level-commands)
  - [Global Flags](#global-flags)
  - [Exit Codes](#exit-codes)
- [Commands](#commands)
  - [Focus](#focus)
  - [Viewport](#viewport)
  - [Move](#move)
  - [Workspace Switching](#workspace-switching)
  - [Move to Workspace](#move-to-workspace)
  - [Monitor Focus](#monitor-focus)
  - [Column Operations (Niri)](#column-operations-niri)
  - [Layout & Sizing](#layout--sizing)
  - [Window Management](#window-management)
  - [UI Toggles](#ui-toggles)
  - [Settings Toggles](#settings-toggles)
  - [Debugging & Tracing](#debugging--tracing)
- [Queries](#queries)
  - [Query Selectors](#query-selectors)
  - [Query Fields](#query-fields)
  - [Query Reference](#query-reference)
- [Window Actions](#window-actions)
- [Workspace Actions](#workspace-actions)
- [Rules](#rules)
  - [Rule Options](#rule-options)
  - [Rule Actions](#rule-actions)
- [Subscriptions](#subscriptions)
  - [Delivery Pipeline](#delivery-pipeline)
  - [Channels](#channels)
  - [subscribe](#subscribe)
  - [watch](#watch)
- [Shell Completion](#shell-completion)
- [Wire Protocol Details](#wire-protocol-details)
  - [Request Format](#request-format)
  - [Response Format](#response-format)
  - [Event Envelope Format](#event-envelope-format)
  - [CLI-Local JSON Errors](#cli-local-json-errors)
- [Error Codes](#error-codes)
- [Output Formats](#output-formats)
- [Environment Variables](#environment-variables)

---

## Architecture

Nehir's IPC system is split across three Swift modules:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  NehirCtl (CLI binary)                                                  │
│  CLIEntry → CLIRuntime → CLIParser → IPCClient                           │
│  CLIRenderer, CLICompletionGenerator                                     │
│  Depends on: NehirIPC only                                             │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ Unix domain socket (NDJSON)
┌────────────────────────────┴─────────────────────────────────────────────┐
│  NehirIPC (shared library)                                              │
│  IPCModels, IPCWire, IPCSocketPath, IPCAutomationManifest                │
│  IPCRuleValidator                                                        │
│  No dependencies                                                         │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │
┌────────────────────────────┴─────────────────────────────────────────────┐
│  Nehir (app)                                                            │
│  IPCServer → IPCConnection → IPCApplicationBridge                        │
│  IPCCommandRouter, IPCQueryRouter, IPCRuleRouter, IPCEventBroker         │
│  Depends on: NehirIPC, AppKit, SkyLight, etc.                          │
└──────────────────────────────────────────────────────────────────────────┘
```

**Request flow:**

```
nehirctl command focus left
    │
    ▼
CLIEntry.main()
    │
    ▼
CLIRuntime.run()
    ├─ local commands: help / completion
    ▼
CLIParser.parse()  ──▶  IPCRequest model
    │
    ▼
IPCClientConnection.send()
    │
    ▼
IPCWire.encodeRequestLine()  ──▶  Unix socket  ──▶  IPCServer
                                           │
                                           ▼
                                   IPCConnection (actor)
                                           │
                                           ▼
                                   IPCApplicationBridge
                                     ├─ auth check
                                     ├─ version check
                                     └─ route to IPCCommandRouter
                                           │
                                           ▼
                                   WMController.commandHandler
                                     (same path as hotkey commands)
                                           │
                                           ▼
                                   ExternalCommandResult
                                           │
                                           ▼
IPCWire.decodeResponse()  ◀──  IPCResponse (JSON)
    │
    ▼
CLIRenderer  ──▶  stdout
```

Local commands such as `help`, `--help`, `-h`, and `completion` never open the IPC socket. `watch` uses the same subscribe request path, then stays client-side to launch one child process per received event.

---

## Installation

### CLI Binary Location

The `nehirctl` binary is bundled inside the Nehir app at:

```
Nehir.app/Contents/MacOS/nehirctl
```

### Installing to PATH

Open **Settings → General → Command Line**. Nehir shows the current CLI status and a button to install or remove the symlink. Nehir chooses the first writable directory already on `PATH` inside your home directory. If none is available, it falls back to `~/.local/bin`, then `~/bin`.

Status values:
- **Homebrew-managed** — CLI is already available from a Homebrew path; Nehir leaves it alone
- **App-managed** — symlink created by Nehir; removable from the same settings row
- **Not installed** — no Nehir-managed CLI link is present yet
- **Conflict** — another file exists at the target path

### Enabling IPC

IPC is disabled by default. Enable it in **Settings → General**, or by adding the key to `~/.config/nehir/settings.toml`:

```toml
[general]
ipcEnabled = true
```

Config files are live-reloaded, so the server starts as soon as the file is saved — no restart needed. Once the server is running, you can toggle it at runtime via:

```
Nehir.app/Contents/MacOS/nehirctl command toggle-ipc
```

Enabling IPC starts the server immediately and creates the Unix domain socket plus the authorization secret file. Disabling it stops the server and removes both files.

---

## IPC Protocol

**Protocol version:** 6

### Socket & Authorization

| Item | Path |
|------|------|
| Socket | `~/Library/Caches/dev.guria.nehir/ipc.sock` |
| Secret | `~/Library/Caches/dev.guria.nehir/ipc.sock.secret` |

The socket path can be overridden with the `NEHIR_SOCKET` environment variable. The secret file path is always `<socket-path>.secret`. For custom socket paths, prefer a private same-user directory such as `$TMPDIR/nehir/ipc.sock` after creating the parent directory with mode `0700`. Avoid shared directories such as `/tmp`.

The authorization token is a random UUID generated each time the IPC server starts. Clients must include this token in every request. The CLI reads it automatically from the secret file.

### Wire Format

The protocol uses **newline-delimited JSON (NDJSON)** — one JSON object per line, terminated by `0x0A`.

- Maximum request size: **64 KB**
- Encoding: UTF-8
- JSON keys: sorted, `camelCase`

Examples in this document are pretty-printed for readability. The actual wire format is compact single-line JSON with the same field names.

### Security Model

1. **Socket permissions:** `0600` (owner-only read/write)
2. **Socket directory permissions:** newly created socket directories are created with `0700`
3. **Secret file permissions:** `0600` (owner-only read/write)
4. **Peer UID check:** server verifies connecting client is the same user via `getpeereid()`
5. **Authorization token:** every request must carry the authorization token stored in plaintext at `<socket-path>.secret`
6. **Session-scoped window IDs:** opaque IDs embed a separate internal session token and are invalidated across restarts — format: `ow_` + base64url(`sessionToken:pid:windowId`)
7. **FD_CLOEXEC:** server-side listening and accepted socket file descriptors are not inherited by child processes
8. **SO_NOSIGPIPE:** prevents SIGPIPE crashes on broken connections
9. **Stale socket cleanup:** server tests existing sockets before overwriting

The trust boundary is the local macOS user account, not individual client processes. Any process running as the same user can read the secret file and use the IPC API once IPC is enabled.

If `NEHIR_SOCKET` points into an existing directory, Nehir reuses that directory as-is instead of re-permissioning it. For custom socket paths, prefer a private directory owned by the same user and avoid shared locations such as `/tmp`.

---

## CLI Reference

```
nehirctl <command> [arguments...] [--format json|table|tsv|text] [--json]
```

### Top-Level Commands

| Command | Type | Description |
|---------|------|-------------|
| `ping` | remote | Verify IPC reachability and return `pong` |
| `version` | remote | Return the Nehir app version and IPC protocol version |
| `command` | remote | Execute window manager commands through the IPC command surface |
| `query` | remote | Query Nehir state, registries, and protocol capabilities |
| `rule` | remote | Manage persisted window rules and reapply them to windows |
| `workspace` | remote | Perform workspace actions such as focusing by workspace name |
| `window` | remote | Perform window actions using session-scoped opaque window IDs |
| `subscribe` | remote | Stream the subscribe handshake plus live event envelopes as JSON |
| `watch` | remote | Consume subscription events and run a child command once per event |
| `help`, `--help`, `-h` | local | Print CLI usage text without connecting to IPC |
| `completion <zsh\|bash\|fish>` | local | Emit a shell completion script without connecting to IPC |

Remote commands require IPC to be enabled. Local commands work even when the IPC server is disabled.

### Global Flags

| Flag | Description |
|------|-------------|
| `--format <format>` | Output format: `json`, `table`, `tsv`, `text` |
| `--json` | Alias for `--format json` |

Global flags must appear before `--exec` in watch commands.

### Exit Codes

| Code | Name | Meaning |
|------|------|---------|
| 0 | success | Command completed successfully |
| 1 | rejected | Server rejected the request |
| 2 | transportFailure | Could not connect to IPC socket |
| 3 | invalidArguments | CLI argument parsing failed |
| 4 | internalError | Unexpected internal error |

---

## Commands

Execute window manager commands. These invoke the same code path as hotkey-bound commands.

```
nehirctl command <command-path> [arguments...]
```

### Focus

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command focus` | `<left\|right\|up\|down>` | command | Focus a neighboring window |
| `command focus previous` | — | niri | Focus the previously focused window |
| `command focus down-or-left` | — | niri | Traverse backward through the active Niri workspace |
| `command focus up-or-right` | — | niri | Traverse forward through the active Niri workspace |
| `command focus-window-in-column` | `<number>` | niri | Focus a window in the focused Niri column by one-based index |
| `command focus-window top` | — | niri | Focus the top window in the focused Niri column |
| `command focus-window bottom` | — | niri | Focus the bottom window in the focused Niri column |
| `command focus-window down-or-top` | — | niri | Focus down in the focused Niri column, wrapping to the top |
| `command focus-window up-or-bottom` | — | niri | Focus up in the focused Niri column, wrapping to the bottom |
| `command focus-window-or-workspace-down` | — | niri | Focus down in the focused Niri column, or switch to the workspace below at the column edge |
| `command focus-window-or-workspace-up` | — | niri | Focus up in the focused Niri column, or switch to the workspace above at the column edge |
| `command focus-column` | `<number>` | niri | Focus a Niri column by one-based index |
| `command focus-column first` | — | niri | Focus the first Niri column |
| `command focus-column last` | — | niri | Focus the last Niri column |

### Viewport

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command scroll-viewport left` | — | niri | Scroll the Niri viewport left to the previous snap point |
| `command scroll-viewport right` | — | niri | Scroll the Niri viewport right to the next snap point |
| `command toggle-viewport-lock` | — | niri | Toggle automatic viewport scroll lock on the active workspace |

### Move

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command move` | `<left\|right\|up\|down>` | command | Move the focused window in the given direction |
| `command move-window-down` | — | niri | Move the focused Niri window down within its column |
| `command move-window-up` | — | niri | Move the focused Niri window up within its column |
| `command move-window-down-or-to-workspace-down` | — | niri | Move the focused Niri window down, or to the workspace below at the column edge |
| `command move-window-up-or-to-workspace-up` | — | niri | Move the focused Niri window up, or to the workspace above at the column edge |
| `command consume-or-expel-window-left` | — | niri | Consume the focused Niri window into the column to the left, or expel it left from its column |
| `command consume-or-expel-window-right` | — | niri | Consume the focused Niri window into the column to the right, or expel it right from its column |
| `command consume-window-into-column` | — | niri | Consume the top window from the next Niri column into the focused column |
| `command expel-window-from-column` | — | niri | Expel the bottom window from the focused Niri column into a new column to the right |

### Workspace Switching

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command switch-workspace` | `<number>` | command | Switch to a workspace by numeric workspace ID on the current monitor |
| `command switch-workspace next` | — | command | Switch to the next workspace |
| `command switch-workspace prev` | — | command | Switch to the previous workspace |
| `command switch-workspace back-and-forth` | — | command | Switch to the previously active workspace |
| `command switch-workspace anywhere` | `<number>` | command | Focus a workspace by numeric workspace ID across all monitors |

### Move to Workspace

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command move-to-workspace` | `<number>` | command | Move focused window to a workspace by numeric workspace ID |
| `command move-to-workspace up` | — | command | Move focused window to the adjacent workspace above |
| `command move-to-workspace down` | — | command | Move focused window to the adjacent workspace below |
| `command move-to-workspace on-monitor` | `<number> <left\|right\|up\|down>` | command | Move focused window to a workspace already assigned to the requested adjacent monitor |

Workspace IDs are positive numeric strings. Direct hotkeys stay limited to `1-9`, but the workspace UI and IPC/CLI both support `10+`.

### Monitor Focus

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command focus-monitor prev` | — | command | Move focus to the previous monitor |
| `command focus-monitor next` | — | command | Move focus to the next monitor |
| `command focus-monitor last` | — | command | Move focus back to the previous monitor |
| `command swap-workspace-with-monitor` | `<left\|right\|up\|down>` | command | Swap active workspace with the workspace on an adjacent monitor |

### Column Operations (Niri)

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command move-column` | `<left\|right\|up\|down>` | niri | Move the focused Niri column |
| `command move-column-to-first` | — | niri | Move the focused Niri column to the first position |
| `command move-column-to-last` | — | niri | Move the focused Niri column to the last position |
| `command move-column-to-index` | `<number>` | niri | Move the focused Niri column to a one-based index |
| `command move-column-to-workspace` | `<number>` | niri | Move focused column to workspace by index |
| `command move-column-to-workspace up` | — | niri | Move focused column to the adjacent workspace above |
| `command move-column-to-workspace down` | — | niri | Move focused column to the adjacent workspace below |
| `command toggle-column-tabbed` | — | niri | Toggle tabbed mode for the focused column. If the focused column is transiently forced-tabbed because its stacked minimum heights overflow the current column, this splits into columns only while the overflow still exists; otherwise it preserves the column. |
| `command toggle-column-full-width` | — | niri | Toggle full-width mode for the focused column |
| `command cycle-column-width forward` | — | command | Cycle column width presets forward |
| `command cycle-column-width backward` | — | command | Cycle column width presets backward |

### Layout & Sizing

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command cycle-window-width forward` | — | niri | Cycle Niri window width presets forward |
| `command cycle-window-width backward` | — | niri | Cycle Niri window width presets backward |
| `command cycle-window-height forward` | — | niri | Cycle Niri window height presets forward |
| `command cycle-window-height backward` | — | niri | Cycle Niri window height presets backward |
| `command expand-column-to-available-width` | — | niri | Expand the focused Niri column into available visible space |
| `command reset-window-height` | — | niri | Reset the focused Niri window height |
| `command set-column-width` | `<size-change>` | niri | Set or adjust the focused Niri column width |
| `command set-window-width` | `<size-change>` | niri | Set or adjust the focused Niri window width |
| `command set-window-height` | `<size-change>` | niri | Set or adjust the focused Niri window height |
| `command balance-sizes` | — | command | Balance layout sizes in the active workspace |
| `command toggle-fullscreen` | — | command | Toggle Nehir-managed fullscreen |
| `command toggle-native-fullscreen` | — | command | Toggle native macOS fullscreen |

`<size-change>` sets an absolute size or adjusts the current one: `100` (points), `50%` (proportion of the working area), `+10` / `-10` (relative points), `+10%` / `-10%` (relative proportion).

### Window Management

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command toggle-focused-window-floating` | — | command | Toggle focused window between tiled and floating |
| `command toggle-focused-window-sticky` | — | command | Toggle the focused managed window's sticky visibility effect |
| `command raise-all-floating-windows` | — | command | Raise all visible floating windows |
| `command rescue-offscreen-windows` | — | command | Clamp tracked floating windows back onto their visible monitors |
| `command scratchpad assign` | — | command | Assign the focused window to the scratchpad |
| `command scratchpad toggle` | — | command | Show or hide the scratchpad window |

When a managed floating window has keyboard focus, focused-window commands target that floating window even if the Niri viewport selection still points at a tiled window underneath it. Sticky command targeting also accepts windows with a sticky source (for example a manually-unstuck PiP) so the user can toggle them back even when the effective sticky state is currently off.

### UI Toggles

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command open-command-palette` | — | command | Toggle the command palette |
| `command open-menu-anywhere` | — | command | Open the menu surface |
| `command open-settings` | — | command | Open the Nehir settings window |
| `command toggle-workspace-bar` | — | command | Toggle workspace bar visibility |
| `command toggle-overview` | — | command | Toggle the overview surface |

### Settings Toggles

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command toggle-focus-follows-mouse` | — | command | Toggle Focus Follows Mouse (experimental) |
| `command toggle-focus-follows-window-to-monitor` | — | command | Toggle Follow Window to Monitor |
| `command toggle-move-mouse-to-focused` | — | command | Toggle Move Cursor to Focused Window |
| `command toggle-borders` | — | command | Toggle window borders (experimental) |
| `command toggle-prevent-sleep` | — | command | Toggle Prevent Display Sleep |
| `command toggle-ipc` | — | command | Toggle the IPC server on/off |

### Debugging & Tracing

These commands are exposed consistently through IPC/CLI, the command palette, and hotkey handling. In the command palette and shortcut settings they appear in the **Debugging & Tracing** category. They require **Developer Mode** to be enabled in Settings → General; when Developer Mode is off they are hidden from the command palette and hotkey list, and IPC returns an error.

| Command | Arguments | Surface | Description |
|---------|-----------|---------|-------------|
| `command debug dump-runtime-state` | — | command | Dump runtime debugging state to the clipboard and unified log |
| `command debug reset-runtime-state` | — | command | Clear runtime debugging state and rebootstrap from a startup-style full rescan |
| `command debug restart-clearing-runtime-state` | — | command | Clear runtime debugging state, relaunch the app, and exit the current process |
| `command debug trace toggle` | — | command | Start runtime debugging trace capture, or stop and export the active capture |
| `command debug trace toggle` | `<active\|inactive>` | command | Ensure trace capture is in the desired state (idempotent; returns `executed` even if already in that state) |
| `command debug capture-recent-trace` | — | command | Export a recent clip from the running trace capture buffer |

The default hotkey is:

- `Ctrl+Option+Cmd+T` — Debug: Toggle Trace Capture

Developer Mode also shows the DebugBar overlay with trace recording, recent-clip export, reset-buffer, retention-cycle, and buffer-status controls. The buffer is tied to the existing trace capture toggle; workspace-bar trace controls were removed so workspace navigation and debug actions stay separate.

Runtime dumps include separate focus-target fields so gesture and hotkey bugs can be diagnosed without conflating concepts: `wmCommandTarget`, `wmCommandTargetSource`, `layoutSelection`, `observedManagedFocus`, `focusRequest`, `borderTarget`, `interactionWorkspace`, `interactionMonitor`, `nonManaged`, `runtimeTraceCaptureActive`, `runtimeTraceStartedAt`, `viewportTraceRecords`, and background trace buffer status fields.

---

## Queries

```
nehirctl query <name> [selectors...] [--fields <field1,field2,...>] [--format json|table|tsv|text]
```

Default output format for queries is `json`.

### Query Selectors

Selectors filter query results. Value selectors take an argument; boolean selectors are flags.

**Value selectors:**

| Selector | Description |
|----------|-------------|
| `--window <id>` | Filter by session-scoped opaque window ID |
| `--workspace <name>` | Filter by workspace raw name, display name, or ID |
| `--display <name>` | Filter by display name or display ID |
| `--app <name>` | Filter by application display name |
| `--bundle-id <id>` | Filter by application bundle identifier |

**Boolean selectors:**

| Selector | Description |
|----------|-------------|
| `--focused` | Only the focused item |
| `--visible` | Only visible items |
| `--floating` | Only floating windows |
| `--scratchpad` | Only the scratchpad window |
| `--current` | Only the current/interaction item |
| `--main` | Only the main display |

### Query Fields

Use `--fields` with a comma-separated list to limit returned fields.

Field tokens are part of the CLI contract. Returned JSON still uses the payload schema's field names, so the selected token may not be byte-for-byte identical to the JSON key. For example, `window-counts` selects the workspace payload's `counts` field.

**Window fields:** `id`, `pid`, `workspace`, `display`, `app`, `title`, `frame`, `mode`, `layout-reason`, `manual-override`, `is-focused`, `is-visible`, `is-scratchpad`, `is-sticky`, `hidden-reason`

**Workspace fields:** `id`, `raw-name`, `display-name`, `number`, `display`, `is-focused`, `is-visible`, `is-current`, `window-counts`, `focused-window-id`

**Display fields:** `id`, `name`, `is-main`, `is-current`, `frame`, `visible-frame`, `has-notch`, `orientation`, `active-workspace`

### Query Reference

| Query | Selectors | Fields | Description |
|-------|-----------|--------|-------------|
| `workspace-bar` | — | — | Workspace bar projection for every monitor |
| `active-workspace` | — | — | Current interaction monitor and active workspace |
| `focused-monitor` | — | — | Current interaction monitor and its active workspace |
| `apps` | — | — | Managed app summary |
| `focused-window` | — | — | Focused managed window snapshot |
| `focused-window-decision` | — | — | Focused window rule/debug decision snapshot |
| `reconcile-debug` | — | — | Reconcile runtime snapshot and recent trace dump for debugging |
| `windows` | `--window`, `--workspace`, `--display`, `--focused`, `--visible`, `--floating`, `--scratchpad`, `--app`, `--bundle-id` | window fields | Managed windows |
| `workspaces` | `--workspace`, `--display`, `--current`, `--visible`, `--focused` | workspace fields | Configured workspaces with occupancy |
| `displays` | `--display`, `--main`, `--current` | display fields | Connected displays with geometry |
| `rules` | — | — | Persisted user window rules |
| `rule-actions` | — | — | Rule action registry |
| `queries` | — | — | Query registry |
| `commands` | — | — | Automation action registry for `command`, `workspace`, and `window` surfaces |
| `subscriptions` | — | — | Subscription registry |
| `capabilities` | — | — | Full protocol capabilities |

**Examples:**

```bash
# List all windows on workspace "main"
nehirctl query windows --workspace main

# Get focused window in table format
nehirctl query focused-window --format table

# List visible floating windows, only return id and title
nehirctl query windows --visible --floating --fields id,title

# Get the active workspace on the current interaction monitor
nehirctl query workspaces --current

# Check server capabilities
nehirctl query capabilities

# Debug why a window was tiled/floated
nehirctl query focused-window-decision

# Dump the reconcile runtime snapshot and recent trace
nehirctl query reconcile-debug
```

`reconcile-debug` returns diagnostic text fields: `snapshot`, `trace`, and `traceLimit`.

---

## Window Actions

Operate on specific windows by their session-scoped opaque ID.

```
nehirctl window <action> <opaque-id>
```

| Action | Description |
|--------|-------------|
| `focus` | Focus a managed window by opaque ID |
| `navigate` | Navigate to a managed window (switches workspace if needed) |
| `summon-right` | Summon a window to the right of the currently focused window |

Window IDs are session-scoped. They become stale after Nehir restarts. Obtain IDs from query results (e.g., `nehirctl query windows`).

---

## Workspace Actions

```
nehirctl workspace focus-name <name>
```

| Action | Arguments | Description |
|--------|-----------|-------------|
| `focus-name` | `<name>` | Focus a workspace by raw workspace ID or unambiguous configured display name |

Numeric inputs are resolved as raw workspace IDs first. Display-name lookup is a convenience path and fails when multiple workspaces share the same display name.

---

## Rules

Manage persisted window rules that control whether matching windows are managed, their layout behavior, sticky visibility, and default workspace placement.
Rule add, replace, and config reload update initial placement defaults; existing managed windows stay on their current workspace unless `rule apply` is used.

```
nehirctl rule <action> [arguments...] [options...]
```

### Rule Options

| Option | Value | Description |
|--------|-------|-------------|
| `--bundle-id` | `<bundle-id>` | Application bundle identifier (required for add/replace) |
| `--app-name-substring` | `<text>` | Match app name containing this substring |
| `--title-substring` | `<text>` | Match window title containing this substring |
| `--title-regex` | `<pattern>` | Match window title against this regex |
| `--ax-role` | `<role>` | Match accessibility role |
| `--ax-subrole` | `<subrole>` | Match accessibility subrole |
| `--manage` | `<auto\|ignore>` | Management action; `ignore` leaves matching windows unmanaged and wins over layout/sticky effects |
| `--layout` | `<auto\|tile\|float>` | Layout action (`auto` = default behavior) |
| `--sticky` | `<true\|false>` | Sticky visibility effect for managed matches; `false` opts out of sticky defaults |
| `--assign-to-workspace` | `<raw-name>` | Open first matching app windows on this workspace raw name |
| `--min-width` | `<points>` | Minimum window width in points |
| `--min-height` | `<points>` | Minimum window height in points |

Bundle IDs must match the pattern: `^[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*$`

### Rule Actions

**Add a rule:**

```bash
nehirctl rule add --bundle-id <bundle-id> [options...]
```

Appends a new rule to the end of the rule list. First matching app windows use its placement defaults; already managed windows are not moved.

**Replace a rule:**

```bash
nehirctl rule replace <rule-id> --bundle-id <bundle-id> [options...]
```

Replaces a rule in-place by its UUID. The rule ID is preserved. Already managed windows are not moved until rules are explicitly applied.

**Remove a rule:**

```bash
nehirctl rule remove <rule-id>
```

Removes a rule by its UUID.

**Move a rule:**

```bash
nehirctl rule move <rule-id> <position>
```

Moves a rule to a new one-based position in the rule list.

**Apply rules:**

```bash
nehirctl rule apply [--focused | --window <opaque-id> | --pid <pid>]
```

Re-evaluates the current rule set against the target. Defaults to `--focused` if no target is specified. This is the explicit path for applying placement rules to already managed windows.

| Target | Description |
|--------|-------------|
| `--focused` | Apply to the currently focused window (default) |
| `--window <id>` | Apply to a specific window by opaque ID |
| `--pid <pid>` | Apply to all managed windows for a process |

**Examples:**

```bash
# Float all Finder windows
nehirctl rule add --bundle-id com.apple.finder --layout float

# Tile initial Safari windows on workspace 2
nehirctl rule add --bundle-id com.apple.Safari --layout tile --assign-to-workspace 2

# Float windows with "Preferences" in the title
nehirctl rule add --bundle-id com.apple.Safari --title-substring Preferences --layout float

# Ignore a helper overlay entirely
nehirctl rule add --bundle-id com.example.Helper --title-substring Overlay --manage ignore

# Force matching media windows sticky, or opt them out of PiP default sticky
nehirctl rule add --bundle-id org.mozilla.firefox --title-substring Picture-in-Picture --layout float --sticky true
nehirctl rule add --bundle-id app.zen-browser.zen --title-substring Picture-in-Picture --sticky false

# Remove a rule
nehirctl rule remove 550e8400-e29b-41d4-a716-446655440000

# Explicitly reapply rules to all windows of a specific app
nehirctl rule apply --pid 12345
```

---

## Subscriptions

Subscribe to real-time state change events from Nehir.

### Delivery Pipeline

`IPCServer.start()` attaches `IPCApplicationBridge` to `WMController`. Controller state changes publish channel snapshots through the bridge, and `IPCConnection` expands the requested channels for each client, sends the initial `subscribe` response, starts per-channel stream tasks, and emits initial snapshots unless `--no-send-initial` is set.

Initial snapshots are best-effort seed state, not a strict ordering barrier. If state changes during subscription setup, a live update can race with the initial snapshot.

Subscription channels are coalesced state streams, not a lossless event log. Slow consumers may only observe the newest buffered update for a channel.

Workspace bar and layout refresh work is only produced when the UI or IPC currently has active consumers.

### Channels

| Channel | Result Type | Description |
|---------|-------------|-------------|
| `focus` | focused-window | Focused window snapshot updates |
| `workspace-bar` | workspace-bar | Workspace bar projection updates |
| `active-workspace` | active-workspace | Interaction monitor and active workspace updates |
| `focused-monitor` | focused-monitor | Focused monitor updates |
| `windows-changed` | windows | Managed window inventory updates |
| `display-changed` | displays | Display state updates |
| `layout-changed` | workspaces | Workspace placement/layout updates |

### subscribe

Stream the subscribe response and subsequent events to stdout as JSON.

```
nehirctl subscribe <channels> [--no-send-initial]
nehirctl subscribe --all [--no-send-initial]
```

Channels are specified as a comma-separated list or with `--all` for all channels.

| Flag | Description |
|------|-------------|
| `--all` | Subscribe to all channels |
| `--no-send-initial` | Skip sending initial state snapshot |

Output is always JSON. Stdout begins with a single pretty-printed `IPCResponse` envelope with `kind: "subscribe"` and `status: "subscribed"`. After that, Nehir emits a best-effort initial state snapshot for each subscribed channel unless `--no-send-initial` is used, followed by live `IPCEventEnvelope` updates as they occur.

**Examples:**

```bash
# Watch focus changes
nehirctl subscribe focus

# Watch all events
nehirctl subscribe --all

# Watch workspace and window changes without initial state
nehirctl subscribe active-workspace,windows-changed --no-send-initial
```

### watch

Subscribe to events and execute a command for each event received. The event data is passed to the child process on stdin.

```
nehirctl watch <channels> [--no-send-initial] --exec <command> [args...]
nehirctl watch --all [--no-send-initial] --exec <command> [args...]
```

The `--exec` flag is required and marks the boundary between watch flags and the child command. Everything after `--exec` is the child command and its arguments.

`watch` consumes the subscribe handshake client-side instead of printing it. It runs one child process per event, waits for that child to finish before handling the next event, writes exactly one NDJSON event line to the child's stdin, and reports non-zero child exits to stderr without terminating the watcher.

**Environment variables passed to child process:**

| Variable | Description |
|----------|-------------|
| `NEHIR_EVENT_CHANNEL` | Subscription channel name (e.g., `focus`) |
| `NEHIR_EVENT_KIND` | Event result kind |
| `NEHIR_EVENT_ID` | Event ID |

The child process inherits the parent's stdout, stderr, and environment. Bare executable names are resolved through `PATH`; use an absolute executable path when you want a fixed command target. The event JSON is written to the child's stdin.

If you persist event streams, prefer a per-user directory such as `~/Library/Logs/Nehir/` and restrictive permissions such as `umask 077`.

**Examples:**

```bash
# Log focus changes to a file
mkdir -p ~/Library/Logs/Nehir
umask 077 && nehirctl watch focus --exec tee -a ~/Library/Logs/Nehir/focus.ndjson

# Run a script on workspace changes
nehirctl watch active-workspace --exec ./on-workspace-change.sh

# Process all events with jq
nehirctl watch --all --exec jq '.result'
```

---

## Shell Completion

Generate shell completion scripts for `nehirctl`.

```
nehirctl completion <zsh|bash|fish>
```

**Setup:**

```bash
# Zsh — add to ~/.zshrc
eval "$(nehirctl completion zsh)"

# Bash — add to ~/.bashrc
eval "$(nehirctl completion bash)"

# Fish — add to ~/.config/fish/config.fish
nehirctl completion fish | source
```

Completions are context-aware: query names, selectors, field names, command paths, channel names, rule actions, and argument values are all completed dynamically based on the automation manifest.

---

## Wire Protocol Details

### Request Format

```json
{
  "version": 6,
  "id": "<uuid>",
  "kind": "<ping|version|command|query|rule|workspace|window|subscribe>",
  "authorizationToken": "<token>",
  "payload": { ... }
}
```

**Payload varies by kind:**

**Command:**
```json
{
  "name": "focus",
  "arguments": {
    "direction": "left"
  }
}
```

**Query:**
```json
{
  "name": "windows",
  "selectors": {
    "workspace": "main",
    "visible": true
  },
  "fields": ["id", "title", "app"]
}
```

**Rule (add):**
```json
{
  "name": "add",
  "arguments": {
    "rule": {
      "bundleId": "com.apple.finder",
      "layout": "float"
    }
  }
}
```

**Subscribe:**
```json
{
  "channels": ["focus", "active-workspace"],
  "allChannels": false,
  "sendInitial": true
}
```

**Workspace:**
```json
{
  "name": "focus-name",
  "workspaceName": "main"
}
```

**Window:**
```json
{
  "name": "focus",
  "windowId": "ow_..."
}
```

### Response Format

```json
{
  "version": 6,
  "id": "<request-id>",
  "ok": true,
  "kind": "<ping|version|command|query|rule|workspace|window|subscribe>",
  "status": "<success|executed|ignored|error|subscribed>",
  "code": null,
  "result": {
    "kind": "<pong|version|workspace-bar|active-workspace|focused-monitor|apps|focused-window|windows|workspaces|displays|rules|rule-actions|queries|commands|subscriptions|capabilities|focused-window-decision|reconcile-debug|subscribed>",
    "payload": { ... }
  }
}
```

Authorization, protocol, validation, and routing failures keep the originating response `kind`. For example:

```json
{
  "version": 6,
  "id": "<request-id>",
  "ok": false,
  "kind": "query",
  "status": "error",
  "code": "unauthorized"
}
```

Malformed or oversized request lines fail before routing and are reported as `kind: "error"` with `code: "invalid_request"` and an empty request id.

### Event Envelope Format

Events are sent on subscription connections after the initial response.

```json
{
  "version": 6,
  "id": "<event-id>",
  "kind": "event",
  "channel": "focus",
  "ok": true,
  "status": "success",
  "result": {
    "kind": "focused-window",
    "payload": { ... }
  }
}
```

The `result` type corresponds to the channel's result kind (see [Channels](#channels)).

### CLI-Local JSON Errors

When JSON output is active and `nehirctl` fails before or outside the IPC request/response path, it emits a client-side failure envelope instead of an `IPCResponse`. This is used for argument parsing failures, transport failures, and unexpected internal CLI errors. `query` and `subscribe` default to JSON output even without an explicit `--json` flag.

```json
{
  "ok": false,
  "source": "cli",
  "status": "error",
  "code": "<invalid_arguments|transport_failure|internal_error>",
  "message": "<human-readable error>",
  "exitCode": 3
}
```

This envelope is produced locally by the CLI, so it does not include IPC fields like `version`, `id`, `kind`, or `result`. The `exitCode` matches the CLI-local failure class: `2` for transport failures, `3` for invalid arguments, and `4` for internal errors.

---

## Error Codes

| Code | Meaning |
|------|---------|
| `invalid_request` | Malformed, oversized, or unparseable request |
| `invalid_arguments` | Bad arguments for the command/rule |
| `invalid_state` | Command is well-formed but not valid in the current runtime state |
| `protocol_mismatch` | Client/server protocol version mismatch |
| `ignored_disabled` | Window manager is disabled |
| `ignored_overview` | Overview surface is open |
| `unauthorized` | Missing or invalid authorization token |
| `stale_window_id` | Window ID is from a previous session or no longer valid |
| `not_found` | Target window, workspace, or rule not found |
| `internal_error` | Unexpected server-side error |

---

## Output Formats

| Format | Description | Default for |
|--------|-------------|-------------|
| `json` | Pretty-printed JSON | queries, subscribe |
| `table` | Aligned columns with headers | — |
| `tsv` | Tab-separated values | — |
| `text` | Simple human-readable text | commands, ping, version |

**Table output example (windows):**

```
ID    PID    APP       TITLE         WORKSPACE  DISPLAY   MODE     FOCUSED  VISIBLE  SCRATCHPAD
ow_…  1234   Terminal  ~             main       Built-in  tiling   yes      yes      no
ow_…  5678   Safari    GitHub        web        Built-in  tiling   no       yes      no
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NEHIR_SOCKET` | Override the default IPC socket path |
| `NEHIR_EVENT_CHANNEL` | (watch child) Subscription channel name |
| `NEHIR_EVENT_KIND` | (watch child) Event result kind |
| `NEHIR_EVENT_ID` | (watch child) Event ID |


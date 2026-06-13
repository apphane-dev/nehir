# Nehir

## Description

Nehir for Raycast lets you control the Nehir window manager from Raycast through the `nehirctl` IPC CLI. It provides quick commands for focus, movement, workspaces, monitors, scratchpad, layout toggles, and a searchable command catalog that discovers available IPC commands and queries.

## Prerequisites

- macOS with Nehir installed
- `nehirctl` available from Nehir.app or installed on `PATH`
- Nehir IPC enabled, for example with `ipc_enabled = true` in `~/.config/nehir/settings.toml`

## Installation

1. Open this extension folder:
   ```bash
   cd raycast/nehir
   ```
2. Install dependencies and start the Raycast development extension:
   ```bash
   mise run raycast:dev
   ```
3. Open Raycast and search for `Nehir:` commands or `Control Nehir`.

## Usage

- Search `Nehir: Focus Left` to focus the neighboring window on the left:
  ```bash
  nehirctl command focus left
  ```
- Search `Nehir: Next Workspace` to switch workspaces:
  ```bash
  nehirctl command switch-workspace next
  ```
- Open `Control Nehir` to browse discovered IPC commands and queries, such as:
  ```bash
  nehirctl query windows --format json
  ```

## Documentation

See the official Nehir IPC and CLI documentation in [`../../docs/IPC-CLI.md`](../../docs/IPC-CLI.md).

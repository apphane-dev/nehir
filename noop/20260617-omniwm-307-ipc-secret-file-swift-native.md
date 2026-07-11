# OmniWM PR BarutSRB/OmniWM#307 — "Fix IPC secret file handling on macOS" — Discovery

Source PR: https://github.com/BarutSRB/OmniWM/pull/307
(author @zicochaos; **closed without merge** — head repository `zicochaos/ipc-start-diagnostics` was deleted 2026-05-19, so the diff is unrecoverable).
Scope of this doc: determine whether the bug the PR fixes applies to nehir,
and whether the PR's fix is safe/needed to port.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM").
Re-verify before implementing; line numbers drift.

> **Filed under discovery/noop/** — the bug this PR targets (a Zig-FFI secret-file
> path failing with `EINVAL` on x86_64 macOS) **cannot exist in nehir**: nehir is
> Swift-native and contains no Zig at all, and the secret-file handling is already
> implemented in pure Swift. Porting the PR's diff is a no-op (it cannot apply:
> there is no Zig FFI to remove) and would, if anything, *add* a Zig dependency
> nehir deliberately lacks. No new repo action is owned here; no sibling doc exists.

---

## TL;DR

- **nehir already does IPC secret-token file read/write in pure Swift via `FileManager`, and never had the Zig-FFI secret path the PR removes — the PR's root cause is structurally impossible here.**
- **Verdict:** 🟢 Fixed — nehir is already at the PR's desired end state; nothing to port.

## Provenance: is this nehir's code?

Yes. The IPC secret-file path lives entirely in nehir's own Swift sources:

- Path derivation — `Sources/NehirIPC/IPCSocketPath.swift:26` (`secretPath(forSocketPath:)` → `socketPath + ".secret"`, pure string concat; suffix constant at `IPCSocketPath.swift:5`).
- Write / create / remove — `Sources/Nehir/IPC/IPCServer.swift` (`writeAuthorizationToken()` at `:185`, `removeExistingSecretIfNeeded()` at `:179`, `secretPath` computed prop at `:334`).
- Read — `Sources/NehirCtl/IPCClient.swift:76` (`resolvedAuthorizationToken()`, reading the secret at `:81-82`).

Crucially, **there is no Zig in nehir whatsoever.** `find . -name '*.zig' -o -name 'build.zig*'` (excluding `.git`) returns nothing, and there are no references to `COmniWMKernels`, any `omniwm_*_solve` FFI symbol, or a `kernels-build` target anywhere in the tree. nehir never adopted the Zig "kernel library" that upstream OmniWM/OmniWM built up in the branch this PR came from (the same branch that added Zig solvers for Niri layout, Dwindle, overview, orchestration, etc.).

## The code in question

The PR summary says it (a) moves IPC secret-token read/write from a Zig-FFI path to Swift/POSIX, keeping Zig only for socket path/socket operations, because "the Zig FFI secret-file path … can fail with EINVAL on x86_64 macOS", and (b) wraps IPC server startup errors with a startup-phase for actionable diagnostics.

nehir's equivalent of the PR's target end state (pure-Swift secret handling):

```swift
// Sources/Nehir/IPC/IPCServer.swift:185
@MainActor
private func writeAuthorizationToken() throws {
    let data = Data((authorizationToken + "\n").utf8)
    guard fileManager.createFile(atPath: secretPath, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
        throw POSIXError(.EIO)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretPath)
}

// Sources/Nehir/IPC/IPCServer.swift:179
@MainActor
private func removeExistingSecretIfNeeded() throws {
    guard fileManager.fileExists(atPath: secretPath) else { return }
    try fileManager.removeItem(atPath: secretPath)
}

// Sources/Nehir/IPC/IPCServer.swift:114   (stop() path)
_ = unlink(secretPath)

// Sources/Nehir/IPC/IPCServer.swift:334
private var secretPath: String {
    IPCSocketPath.secretPath(forSocketPath: socketPath)
}
```

```swift
// Sources/Nehir/IPC/IPCClient.swift:76   (CLI side reads the token)
private func resolvedAuthorizationToken() -> String? {
    if let authorizationToken { return authorizationToken }
    let secretPath = IPCSocketPath.secretPath(forSocketPath: socketPath)
    guard let data = fileManager.contents(atPath: secretPath),
          let token = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty
    else { return nil }
    return token
}
```

```swift
// Sources/NehirIPC/IPCSocketPath.swift:26
public static func secretPath(forSocketPath socketPath: String) -> String {
    socketPath + secretSuffix   // secretSuffix = ".secret"  (IPCSocketPath.swift:5)
}
```

## Why this is already fixed / doesn't apply

**1. The root cause does not exist.** The PR's bug is a Zig-FFI routine (`open`/`write` of the secret token through the C ABI) returning `EINVAL` on x86_64 macOS, which it attributes to an entitlement/handling failure in that FFI path. nehir has no such routine: there is no `.zig` source, no Zig-built static library, and no `omniwm_*` FFI symbol in the build. The secret token is read/written by `FileManager` from Swift directly (`IPCServer.swift:185`, `IPCClient.swift:81-82`). The `EINVAL`-from-Zig failure mode therefore cannot reproduce in nehir on any architecture, x86_64 included.

**2. nehir is already at the PR's desired end state.** The PR's headline change is "move IPC secret token read/write handling to Swift/POSIX." nehir's secret handling *has always been* Swift/POSIX (`FileManager.createFile` + `setAttributes` with `0o600` at `IPCServer.swift:187,190`). Socket-path derivation is likewise pure Swift (`IPCSocketPath.swift:26`), matching the PR's "keep socket path derivation … in [Swift-equivalent]" outcome. There is no FFI boundary to migrate.

**3. The PR's secondary change (phase-tagged startup diagnostics) is already covered functionally.** nehir wraps IPC start failures in `AppDelegate.swift`: the live start path (`:136`) and the toggle path (`:117`) both catch throws and surface `"IPC Failed to Start"` with `error.localizedDescription` (`AppDelegate.swift:120`, `:139`), then disable IPC. The PR's "wrap IPC server startup errors with the startup phase" is a richer enum-tagged variant of exactly this; nehir's existing handling already makes an IPC-start failure actionable to the user. Not a regression, not a port requirement.

**Observation (not this PR's bug):** the PR's Swift rewrite bundled defensive hardening — `O_NOFOLLOW` (symlink rejection), an explicit owner check, and regular-file validation on the secret read. nehir's Swift read path (`IPCClient.swift:79-90`) does `FileManager.contents(atPath:)` without those explicit guards. This is a potential future hardening, **not** the bug PR BarutSRB/OmniWM#307 exists to fix (the bug is the Zig `EINVAL`, which is absent here), and nehir already defends the connection at a separate boundary: every accepted client must pass the `getpeereid` peer-credential check `isCurrentUser(_:)` (`IPCServer.swift:325`) and the socket directory is created `0o700` (`IPCServer.swift:174`). The secret token is not the sole auth gate. Recording this as an aside; it does not change the verdict and does not belong to this item.

## Recommendation

Do **not** port PR BarutSRB/OmniWM#307. The fix it ships (a Swift secret-file path replacing a failing Zig-FFI one) is already nehir's implementation, and the bug it fixes is structurally impossible here (no Zig layer exists). Attempting to apply the diff would be a no-op against `Sources/` at best, or would reintroduce a Zig dependency at worst. Close as not-applicable to nehir.

(Out of scope for this item, but worth a separate, dedicated discovery if anyone wants it: add `O_NOFOLLOW` + owner/regular-file validation to the secret read in `IPCClient.swift:76-90`. That is independent hardening, not a BarutSRB/OmniWM#307 backport.)

## Suggested tests

N/A — nothing to change. If the optional symlink/owner-hardening aside is ever pursued independently, it would merit tests asserting (a) a symlinked secret path is rejected, and (b) a secret not owned by the current uid is rejected. That belongs to a future item, not this doc.

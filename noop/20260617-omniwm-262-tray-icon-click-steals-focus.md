# OmniWM issue #262 — "Tray-icon click steals focus" — Discovery

Source issue: <https://github.com/BarutSRB/OmniWM/issues/262>
Scope of this doc: determine whether the symptom reproduces in nehir — clicking a
menu-bar tray/status-item icon (e.g. Proton Pass, Yubico Authenticator)
unnecessarily focuses that app's window, stealing focus from the active tiled
window — and whether any fix is needed.

All file/line references were verified against the Nehir source tree
at `904df02` ("Add bunch of discoveries mapped to issues from OmniWM"). Re-verify
before implementing; line numbers drift.

> **Filed under `discovery/noop/`** — the focus change is a direct consequence of
> macOS app activation (interacting with an app's status item makes that app
> frontmost), which nehir legitimately tracks. nehir already routes the common
> tray-app case (popover/panel surfaces) through non-managed focus so the managed
> focus is preserved, and excludes `.accessory`/`.prohibited` apps from
> pointer-targeting. macOS does not expose a reliable "activated via status item"
> signal, so a suppress-by-source fix would be fragile, and there is no upstream
> fix to port. No new repo action is owned here.

---

## TL;DR

- **Clicking a tray icon activates the owning app (macOS behavior); nehir then
  follows the app's frontmost window, which is expected.** For popover-based
  tray apps nehir preserves managed focus (non-managed focus for the panel); for
  `.regular` apps that raise a real window, following that window is correct.
- **Verdict:** ⚪ **Won't port / Not applicable.** Not a nehir-specific bug; no
  reliable signal to suppress it, and nothing to port.

## Issue context

- **State:** open; low priority. No linked PR, no fix to port.
- **Symptom (verbatim):** "Whenever I click on their tray icons even if I don't
  select an option and click somewhere else it focuses that application's window
  unnecessarily." (Proton Pass, Yubico Authenticator; both expose menu-bar status
  items.)

## Provenance: is this nehir's code?

Yes — nehir has the relevant app-activation and focus machinery:

- App-activation handling with `ActivationEventSource`
  (`Sources/Nehir/Core/Controller/AXEventHandler.swift:58`/`:1267`), focus
  confirmation (`focusConfirmed(token:workspaceId:source:)`, `:66`), and the
  non-managed-focus fallback for unmanaged/transient surfaces
  (`nonManagedFallbackEntered(pid:source:)`, `:68`).
- `appPolicy` (activation policy) threaded through window classification
  (`AXEventHandler.swift:3060` → `AXWindowService.collectWindowFacts(appPolicy:)`).
- An `activationPolicy != .regular` exclusion for non-regular apps in the
  unmanaged/pointer-target path
  (`Sources/Nehir/Core/Controller/WMController.swift:2524`).

## Why the bug does not apply cleanly to nehir

1. **The focus follow-on is macOS app-activation semantics, not a nehir
   mechanism.** Interacting with an app's `NSStatusItem` makes that app
   frontmost (`NSApplication` activation). nehir, like any WM that tracks the
   frontmost app's focused window, then observes the `focusedWindowChanged` AX
   event and confirms focus for whatever window the app actually raised. If the
   app raises its main window, focusing it is correct; if the app only shows a
   popover and the user clicks away, no persistent managed-focus change is
   warranted.

2. **nehir already preserves managed focus for the common tray-app case.**
   Popover/panel surfaces raised by tray apps are classified as non-standard /
   floating (dialog/panel subroles, with `appPolicy` factored into
   classification at `AXEventHandler.swift:3060`) and routed through the
   non-managed-focus path (`nonManagedFallbackEntered`, `:68`), which surfaces
   the panel on top without changing the confirmed managed focus token.

3. **Tray-only (`.accessory`/`.prohibited`) apps are already excluded from
   pointer targeting** (`WMController.swift:2524`:
   `activationPolicy != .regular → continue`), so such apps' windows are not
   promoted to managed focus on hover/FFM.

4. **No reliable suppression signal exists, and no upstream fix to port.**
   macOS does not distinguish "app activated because the user clicked its status
   item" from "app activated normally" in a way a third-party WM can robustly
   read. A heuristic suppress-on-status-item-activation would be fragile (and
   would also suppress legitimate activations where the user *did* want that
   app's window). The issue carries no merged fix.

## Recommendation

**Do nothing / do not port.** Treat focus-follow-on from app activation as
expected behavior. If a concrete, reproducible case is found where nehir changes
the *confirmed managed focus* to a window the user never raised (e.g. an app that
activates silently), investigate it as a focused-window-changed handling bug with
the specific pid/window and the `focus_confirmed` / `non_managed_fallback_entered`
trace lines — not by adding an unreliable status-item-activation suppressor.

## Suggested tests

(none required for a won't-port verdict; the existing non-managed-focus and
accessory-app-exclusion coverage pins the relevant behavior.)

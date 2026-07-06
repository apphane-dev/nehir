# Shareable/installable app-rule catalog — feasibility and required format changes

Status: discovery (design exploration). Verified against `main` on 2026-07-06.
Motivated by discussion #142 (Thunderbird dialog) and the cross-WM prior art in
[[20260706-thunderbird-gecko-dialog-tiled-untagged-unparented-standard-window]]:
AeroSpace and yabai both accrete per-app window hacks, and Nehir is starting to do
the same. The idea under test: **convert Nehir's built-in per-app hacks into a
catalog of shareable/installable rules** instead of hard-coding them.

This document challenges that idea against the *actual* current built-ins and
states precisely what the `AppRule` format would need to grow to make it real.

---

## The current built-ins split into two populations

### Category A — identity rules (already `AppRule` values)

Constructed as `AppRule` structs in
`Sources/Nehir/Core/Rules/WindowRuleEngine.swift` → `makeBuiltInRules()`:

| Built-in | Shape | Signals |
| --- | --- | --- |
| `defaultFloatingApp` (`DefaultFloatingApps.bundleIds`, 8 apps: System Settings, Simulator, PhotoBooth, Calculator, Screen Sharing, Remote Desktop, unlockgo) | `{bundleId, layout=float}` | bundleId |
| `browserPictureInPicture` (firefox, zen) | `{bundleId, titleRegex="^Picture-in-Picture$", layout=float}` | bundleId + title |

These are pure app-identity knowledge and are **already declarative**. They are
catalog-ready today with **zero format change** — they only need packaging,
provenance, and a delivery mechanism.

### Category B — structural / heuristic decisions (hand-coded functions)

These live as imperative methods in `decision(...)` and key on signals the
`AppRule` matcher set does not expose:

| Built-in | Keys on | App-scoped? |
| --- | --- | --- |
| `systemTextInputPanel` → unmanaged | bundleId **set** | yes (bundleId set) |
| `ghosttyQuickTerminalOverlay` → unmanaged | bundleId + `windowServer.level != 0` | yes |
| `transientSystemDialogSurface` → unmanaged | `subrole==AXSystemDialog && parentId==0` | **no — app-agnostic** |
| `parentedWindowServerSurface` → float | `parentId != 0` | **no — app-agnostic** |
| `transientWindowServerSurface` (#98) → float | `hasFloatingTag && !hasDocumentTag` | **no — app-agnostic** |
| `cleanShotRecordingOverlay` → float | bundleId + subrole + `level==103` | yes |
| `pipDefaultStickyCandidate` → sticky | level range + tags + button presence + subrole | **no** |
| `degradedWindowServerChildSurface` → unmanaged | `!attributeFetchSucceeded` + transient evidence | **no** |
| `heuristicDisposition` fallback | close/fullscreen/zoom/minimize buttons + enabled state + accessory policy + subrole | **no** |

These are not "which app misbehaves" facts — they are **windowing-system
reverse-engineering**: invariants about WindowServer tags, levels, parent
relationships, and AX button state. Nobody would "install" the parented-surface
rule; it is engine behavior, not a shareable per-app tweak.

---

## The core tension

The motivating cases sit on the **boundary** between the two populations:

- The Thunderbird Gecko dialog ([[20260706-thunderbird-gecko-dialog-tiled-untagged-unparented-standard-window]])
  and AeroSpace's hardcoded Firefox minimize-button branch are **per-app in scope**
  (`org.mozilla.*`) but **structural in signal** (WindowServer document tag /
  minimize-button-enabled). They belong to Category B by signal but Category A by
  intent.

So "convert per-app hacks to a catalog" bifurcates:

- **Identity layer (Category A):** genuinely benefits from a catalog. This is the
  crowd-sourceable "app X wants floating" knowledge. Ships with no format risk.
- **Structural layer (Category B, app-agnostic):** should stay engine code. It is
  not shareable per-app knowledge, needs signals the format lacks, and its members
  interact through a hardcoded precedence order that a flat catalog cannot
  reproduce.
- **Boundary cases (per-app + structural signal):** these are the *only* reason to
  grow the format, and they force the real cost decision below.

---

## Hard blockers in the current `AppRule` format

Grounded in `Sources/Nehir/Core/Config/AppRule.swift`:

1. **`bundleId` is mandatory** (`var bundleId: String`; `matches()` returns false
   on any bundleId mismatch). Every rule must name one app. The three most
   powerful structural built-ins (`parentedWindowServerSurface`,
   `transientWindowServerSurface`, `transientSystemDialog`) are app-agnostic and
   **cannot be expressed at all** without making bundleId optional/wildcard.
2. **No structural matchers.** The full matcher set is
   `{bundleId, appNameSubstring, titleSubstring, titleRegex, axRole, axSubrole}`.
   No windowServer level / parent / tags, no AX button presence or *enabled*
   state, no activation policy, no attribute-fetch-failed.
3. **No negation / exclusion.** AeroSpace's generic heuristic is
   `float if no-fullscreen-button EXCEPT chrome, gimp, alacritty, steam, iterm2,
   emacs, vscode…`. Positive-only matchers cannot express "the heuristic minus
   these apps," so the *generic* heuristics can never be cataloged, only per-app
   overrides.
4. **No provenance / versioning / precedence on persisted rules.** `AppRule` has
   no source, package, version, or disabled flag. `WindowDecisionSource`
   distinguishes builtin vs user only at *decision* time, not in storage. A
   catalog needs all of these to update, disable, and layer rules safely.

---

## What the format would need to change

To make the catalog actually absorb the boundary cases (Gecko dialog, Firefox),
not just the trivial identity list:

### A. Matcher additions (new optional tri-state keys — AND-combined, additive)

- `windowServerLevel` (int, or an enum `normal` / `nonNormal` plus `==N`)
- `hasParent: Bool?` (parentId != 0)
- surface tags: `documentTag` / `floatingTag` / `modalTag` as `Bool?` — the
  Thunderbird discriminator is `documentTag == false`
- button enabled-state: `fullscreenButtonEnabled` / `minimizeButtonEnabled` /
  `hasCloseButton` as `Bool?` — AeroSpace's Firefox discriminator
- `activationPolicy` (`regular` / `accessory`)

All optional and AND-combined, so the JSON/TOML stays backward-compatible for
*parsing*. But an older **engine** cannot enforce them — see (D).

### B. `bundleId` → optional or list/glob

Needed both to allow app-agnostic structural rules and to package families
(`org.mozilla.*`) without the current row-per-app explosion
(`DefaultFloatingApps` is literally 8 rows for one concept).

### C. Packaging metadata + explicit layering (the bulk of the real work)

- per-rule `source` / `package` id + `catalogVersion` + `disabled: Bool`
- a documented precedence: **system-structural (code) < installed-catalog <
  user-override**. This is already the *de facto* order today — the structural
  functions short-circuit before user rules, and `DefaultFloatingApps` fires
  after explicit user/built-in rules. Formalizing this layering is the safe path.
- a way to disable/override a catalog rule **without editing it**, so catalog
  updates don't clobber user intent (and user intent doesn't fork the package).

### D. Engine-version / capability gating (fail-closed)

A shared rule may reference a matcher a given Nehir build lacks. The format needs
`minEngineVersion` or a per-rule capability tag, and the loader must **skip
unsupported rules with a surfaced warning — never silently mis-tile**. Without
this, a shared rule degrades into wrong behavior on older builds rather than
being inert.

### E. Disposition parity (mostly already covered)

Catalog rules must emit `float`, `tile`, `unmanaged` (ignore), and `sticky`.
`AppRule` already has `manage=ignore` + `sticky`, so the gap is small, but the
`unmanaged` (don't touch) vs `float` (managed-but-floating) distinction must be
explicit in the `manage`/`layout` combination and documented.

---

## Recommendation

1. **Ship the catalog scoped to the identity layer (Category A) first.** Package
   `DefaultFloatingApps` + PiP + future "app X floats" entries as an installable,
   versioned catalog with provenance and a disable/override toggle (C). Zero
   matcher changes; the whole cost is packaging + precedence + gating machinery.
2. **Keep the app-agnostic structural heuristics (Category B) in engine code.**
   Do not try to catalog them; they are invariants, not shareable tweaks.
3. **Treat the boundary cases as the gate for growing matchers.** Only when a
   real per-app-but-structural need lands (Thunderbird is the first) do we add the
   minimal matcher slice — start with surface tags (`documentTag`) and/or
   button-enabled — behind capability gating (D). The immediate Thunderbird fix
   ships as an engine built-in now
   ([[20260706-thunderbird-gecko-dialog-float-builtin]]); if a second Gecko/other
   case appears, promote `documentTag`/`minimizeButtonEnabled` to a catalog
   matcher rather than adding a second hardcoded family. (The Thunderbird fix
   shipped as an engine built-in on `main` `45d3767f` on 2026-07-06 —
   [[20260706-thunderbird-gecko-dialog-float-builtin]] — so the `documentTag`
   matcher is the concrete first candidate whenever a second such case lands.)

Net: the catalog is worth building, but its honest v1 is a **packaging + provenance
+ precedence + gating** system over the rules Nehir *already* expresses
declaratively — not a new matcher DSL. The matcher DSL is a later, demand-driven
increment whose first customer is the Gecko-dialog class.

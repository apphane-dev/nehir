# Notice

Nehir is a fork of OmniWM by BarutSRB:

- https://github.com/BarutSRB/OmniWM

Nehir forks from OmniWM and is maintained independently. As of this notice,
upstream is again using the **OmniWM** name for development and releases.

## The Hiro interlude

Upstream was briefly renamed to **Hiro** with a full rewrite announced under
that name. The Hiro discussions, branding, and announcement are no longer
publicly available in that form, and the repository has returned to the OmniWM
name. An archived copy of the original Hiro rewrite announcement is preserved:

- https://web.archive.org/web/20260610213855/https://github.com/BarutSRB/Hiro/discussions/399

None of this changes Nehir's origin: the code Nehir forks from is OmniWM, and
development here continues independently of whatever happens upstream.

## Relationship to upstream

Nehir is not affiliated with or endorsed by the upstream author. It has diverged
in layout behavior, settings, defaults, and maintenance direction, with a
deliberately narrower, Niri-style scope. Nehir is a GPL project; fixes that land
here are welcome to be reused or backported upstream.

## Source attribution policy

Nehir keeps upstream attribution visible because this project exists thanks to
OmniWM being released as free software. Upstream OmniWM itself carries this
notice on every source file:

```text
// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM
```

The fork base predates per-file attribution: neither OmniWM at the fork point
nor Nehir's source tree carried per-file notices. Upstream OmniWM has since
introduced its own per-file notice, and Nehir now introduces a structured form
too — making upstream authorship explicit on every file and separating legal
authorship from project lineage. Each shipped Swift file carries an SPDX block
with one of two provenance markers:

- **`Provenance=upstream-derived`** — the file originates from OmniWM (copied,
  adapted, or significantly rewritten in Nehir). It carries **two** copyright
  lines, preserving upstream authorship **in addition to** Nehir's:
  ```text
  // SPDX-FileCopyrightText: 2026 BarutSRB
  // SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
  // SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
  //
  // SPDX-License-Identifier: GPL-2.0-only
  ```
  Exact upstream commit hashes for a few post-fork-base borrows are tracked in
  `.provenance.json`'s non-rendering `upstreamCommits` map and in the provenance
  audit, not rendered into every file header. Each path maps to an array of
  `{repo, hash}` entries, so a file can record more than one borrow, including
  from different upstream sources.

- **`Provenance=nehir-original`** — the file was written from scratch for Nehir
  with no prior existence anywhere in OmniWM. It carries only Nehir copyright:
  ```text
  // SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
  // SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
  //
  // SPDX-License-Identifier: GPL-2.0-only
  ```

`SPDX-License-Identifier`, `SPDX-FileCopyrightText`, and `SPDX-FileComment` are
standard SPDX file tags. The `Provenance=`, `Upstream-Project=`,
`Upstream-Author=`, and `Nehir-Changes-Since=` keys inside `SPDX-FileComment`
are Nehir's own convention, documented here; SPDX lets a file comment carry
arbitrary structured text, but does not standardize these keys.

The default marker is `upstream-derived`: this is the conservative choice for a
GPL-2.0-only fork (most files originate upstream), so any new file is assumed to
be upstream-derived until it is explicitly reclassified. A file is marked
`nehir-original` only when its own code is absent from all of upstream history.
This split is backed by a file-by-file provenance audit recorded on the `plans`
branch under `provenance/`.

Rules of thumb:

- Do **not** add `2026 BarutSRB` to a file merely as thanks — only to files that
  actually contain OmniWM-origin code. New from-scratch Nehir files go in the
  `nehir-original` override (Nehir-only copyright).
- Do **not** drop `2026 BarutSRB` from files derived from OmniWM. Upstream
copyright is preserved **in addition to** Nehir's, never instead of it.
- For a file later shown to be copied or heavily adapted from a specific upstream
  commit, record that commit in `.provenance.json`'s `upstreamCommits` audit map
  and in the durable provenance audit. Keep rendered headers focused on stable
  legal facts instead of per-file commit bookkeeping.

Generated Swift headers are driven by `.provenance.json` and the mise task files
under `.config/mise/tasks/license/` (`mise run license`, `mise run license:check`).

## Git history

This repository ships a squashed/fresh Git history to keep the clone small. The
pre-squash Nehir fork history is preserved separately:

- https://github.com/Guria/OmniWM

The absence of the upstream Git history in this repository does not remove
upstream authorship, copyright, or licensing context.

## License

Nehir is distributed under GPL-2.0-only. See `LICENSE`.

---
"nehir": patch
---

Surface license attribution across About, nehirctl, and source headers

- About tab now shows GPL-2.0-only, OmniWM lineage, and links to LICENSE and
  NOTICE.md.
- `nehirctl` gains `license`/`about`/`legal`/`attribution` commands plus
  license/attribution lines in `--help`.
- Source files carry generated SPDX headers: upstream-derived files keep the
  BarutSRB copyright alongside Nehir contributors; nehir-original files carry
  Nehir only. NOTICE.md documents the policy.
- Current project/source links point to the apphane-dev Nehir repository while
  preserving upstream OmniWM and historical fork links.

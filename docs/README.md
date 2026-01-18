# Docs

This repository contains two macOS apps:

- `Hypnograph/` (target: `HypnographApp`)
- `Divine/` (target: `DivineApp`)

Both share `HypnoCore/` (and `HypnoUI/`).

## Current Layout

- `docs/architecture/` — architecture notes (currently a mix of shared + app-specific details)
- `docs/projects/` — planning docs and historical implementation notes
- `docs/reference/` — user-facing reference (e.g., controls)

## Planned Layout (Future Cleanup)

To reduce confusion, a future docs-only refactor can split app-specific docs from shared core docs:

- `docs/` — shared, core docs (primarily `HypnoCore`)
- `Hypnograph/docs/` — Hypnograph-specific docs
- `Divine/docs/` — Divine-specific docs

This will require updating intra-doc links and any references from code comments/README files.

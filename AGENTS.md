# Repository Working Rules

## Documentation routing

This repo contains two apps plus shared libraries:
- `docs/hypnograph/`
- `docs/divine/`
- `docs/shared/`

When a documentation task does not explicitly name a target app:
- default to `docs/hypnograph/`

Place docs by scope:
- Hypnograph-only behavior, UI, roadmap, or architecture: `docs/hypnograph/`
- Divine-only behavior, UI, roadmap, or architecture: `docs/divine/`
- Cross-app behavior, shared libraries, ontology, or standards: `docs/shared/`

If scope is unclear:
- create/update under `docs/hypnograph/`
- include a short note about the assumption in the doc

## Documentation lifecycle

Within each scope (`hypnograph`, `divine`, `shared`), use:
- `roadmap.md` for current work tracking
- `projects/backlog/` for planned work not started
- `projects/` root for active work
- `archive/` for completed work (`YYYYMMDD-project-name.md`)

Do not place new project docs at `docs/` root.
Do not use `docs/active/` for new work.

## First file to check

Before making documentation updates, read:
- `docs/README.md`
- then the scope README (`docs/hypnograph/README.md`, `docs/divine/README.md`, or `docs/shared/README.md`)

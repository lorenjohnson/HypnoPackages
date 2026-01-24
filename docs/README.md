# Documentation

This `docs/` folder contains product specs, architecture notes, and project planning for this repo.

## Structure

```text
docs/
├── hypnograph/         # Hypnograph app docs
│   ├── projects/       # active projects
│   │   └── backlog/    # planned, not started
│   ├── archive/        # completed projects
│   ├── architecture/   # system design
│   ├── product/        # mission, practices
│   ├── reference/      # user-facing docs
│   ├── roadmap.md      # open loops
│   └── index.md        # entry point
├── divine/             # Divine app docs
│   ├── projects/
│   │   └── backlog/
│   ├── archive/
│   ├── roadmap.md
│   └── index.md
├── shared/             # cross-app docs
│   ├── ontology/       # generated diagrams
│   └── index.md
└── README.md           # this file
```

## Entrypoints

- [hypnograph/index.md](hypnograph/index.md) — Hypnograph documentation
- [divine/index.md](divine/index.md) — Divine documentation
- [shared/index.md](shared/index.md) — Shared documentation

## Project Lifecycle

Each app follows the same lifecycle pattern:

```text
roadmap.md  →  projects/backlog/  →  projects/  →  archive/
(idea)         (planned)            (active)      (done)
```

1. Ideas captured in `roadmap.md`
2. When ready to plan: create doc in `projects/backlog/`
3. When starting work: move to `projects/` root
4. When complete: move to `archive/` with date prefix

## Conventions

### Naming

- **Directories & files:** kebab-case (`volume-leveling`, `roadmap.md`)
- **Projects:** kebab-case (`project-name/` or `project-name.md`)
- **Completed projects:** date-prefixed with completion date (`YYYYMMDD-project-name/`), moved to `archive/`

### Project docs

Each project doc should include:

- `# <Project Name>`
- `## Overview` (what/why, scope)
- `## Plan` (phases/steps)
- `## Open Questions` (unknowns)
- `## Notes` (links, references)

Optional front matter:

```yaml
---
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active | backlog | archived
---
```

### Linking

- Use relative links within the same app folder
- Use `../` paths when linking across app folders

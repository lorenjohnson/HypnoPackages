# Documentation (Draft: Current + Target Layout)

This `docs/` folder is the source of truth for product specs, architecture notes, and project planning for this repo.

This document intentionally describes **both**:

- **Current layout** (what exists today)
- **Target layout** (a planned docs refactor we have *not* done yet)

When we are ready, we will track the transition as a dedicated project and update links + filenames in one focused pass.

---

## Goals

- Make docs easy to navigate with “quick open” (avoid dozens of `overview.md` / `implementation-plan.md` collisions).
- Keep project specs systematic so they’re easy to maintain during AI-assisted development.
- Keep only a small number of “active” project docs in your face; keep backlog/archive accessible but not noisy.
- Keep docs versioned alongside code so specs and implementation stay in sync across branches.

---

## Current Layout (Today)

App-specific docs currently live under:

- `docs/Hypnograph/`
- `docs/Divine/`

Shared/core docs:

- `docs/ontology/` (generated artifacts + curated diagram doc)

Notes:

- Projects are currently a mix of single files and per-project folders.
- Many project folders contain separate `overview.md` and `implementation-planning.md` documents.

---

## Target Layout (Planned)

### Entrypoints / indexes

These are the “start here” docs you open most often:

- `docs/Hypnograph.md` — Hypnograph index (active work, backlog, key architecture links)
- `docs/Divine.md` — Divine index (active work, backlog, key architecture links)
- `docs/README.md` — this document (the contract for structure + conventions)

### Shared documentation

- `docs/architecture/` — shared architecture docs (HypnoCore/HypnoUI + product-specific notes where needed)
- `docs/reference/` — user-facing reference (controls, behaviors)
- `docs/ontology/` — generated ontology + curated diagrams (shared)

### Projects

Projects are stored as **one markdown file per project** with a unique name:

- `docs/projects/YYYYMMDD-project-slug.md` — active projects (default)
- `docs/projects/backlog/YYYYMMDD-project-slug.md` — not currently active
- `docs/projects/archive/YYYYMMDD-project-slug.md` — completed projects

Rationale:

- The filename is unique, so quick open is always unambiguous.
- A project doc is a single “living spec” that can be updated incrementally during implementation.
- We only create a per-project directory when we have additional artifacts (e.g. Figma exports, diagrams, screenshots).

When a project needs assets later, the project can be promoted to:

- `docs/projects/YYYYMMDD-project-slug/README.md` (main spec)
- `docs/projects/YYYYMMDD-project-slug/assets/` (optional)

---

## Conventions (Target)

### Project doc template

Each project doc should follow the same shape so updates are mechanical:

Front matter (required):

```yaml
---
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active | backlog | archived
depends_on:
  - YYYYMMDD-other-project-slug (optional)
---
```

Sections (recommended order):

- `# <Project Name>`
- `## Overview` (what/why, scope, success criteria)
- `## Plan` (phases/steps, ordered)
- `## Open Questions` (explicit unknowns)
- `## Decisions` (short log of decisions and rationale)
- `## Notes` (links, related docs, implementation references)

### Status rules

- Directory location and front matter should match:
  - `docs/projects/` → `status: active`
  - `docs/projects/backlog/` → `status: backlog`
  - `docs/projects/archive/` → `status: archived`
- Moving a project between folders is the primary way to change “what you see day-to-day”.

### Naming rules

- Prefer `YYYYMMDD-short-kebab-slug.md`.
- Use `Plan` consistently (avoid mixing “implementation plan” vs “implementation planning” across docs).
- Avoid duplicate filenames like `overview.md` unless the file is uniquely named by its parent folder and you really need that folder.

### Linking rules

- Prefer relative links when linking within the same directory.
- Prefer repo-root-relative paths (like `docs/projects/...`) when linking across directories so links survive moves.

---

## Planned Migration (Future Project)

When we’re ready to adopt the target layout:

- Create `docs/Hypnograph.md` and `docs/Divine.md` and treat them as the only “index” docs.
- Flatten existing project folders into one file per project (merge overview + plan into a single doc).
- Rename project docs to `YYYYMMDD-project-slug.md`.
- Move inactive work into `docs/projects/backlog/` and completed work into `docs/projects/archive/`.
- Update internal links and remove obsolete paths.
- (Optional) Configure editor/search defaults to reduce noise from `docs/projects/archive/`.

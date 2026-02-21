# Docs (structure + rules)

Documentation is treated as part of the product and kept intentionally simple.

This repo currently contains two apps plus shared libraries:
- `docs/hypnograph/` for Hypnograph-only documentation
- `docs/divine/` for Divine-only documentation
- `docs/shared/` for cross-app/shared-library documentation

Default routing rule:
- If a docs request does not explicitly name a target app, assume it is for Hypnograph and place it under `docs/hypnograph/`.

## Structure

```text
docs/
├── README.md
├── hypnograph/
│   ├── README.md
│   ├── roadmap.md
│   ├── active/
│   ├── archive/
│   ├── architecture/
│   ├── backlog/
│   ├── product/
│   ├── reference/
│   └── user-testing/
├── divine/
│   ├── README.md
│   ├── roadmap.md
│   ├── active/
│   └── archive/
│   ├── backlog/
├── shared/
│   ├── README.md
│   ├── active/
│   ├── archive/
│   ├── backlog/
│   └── ontology/
└── agents/
```

## Routing rules

Use these rules whenever deciding where docs should go:

1. Put it in `docs/hypnograph/` when the work is app-specific to Hypnograph UI, behavior, architecture, or roadmap.
2. Put it in `docs/divine/` when it is specific to Divine product behavior or roadmap.
3. Put it in `docs/shared/` when it affects both apps, shared libraries, shared ontology, or cross-app standards.
4. If scope is uncertain, default to `docs/hypnograph/` and note assumptions in the doc.

## Workflow

Each scope (`hypnograph`, `divine`, `shared`) follows the same lifecycle:

`roadmap.md` -> `backlog/` -> `active/` -> `archive/`

- Current work is listed in `<scope>/roadmap.md`; if a project has a write-up, link it there.
- Do not keep a completed-project list in roadmap files; completed work lives in `<scope>/archive/`.
- If a project is not currently active, keep it in `<scope>/backlog/`.
- When a project is completed:
  - set front matter `status: completed`
  - add `completed: YYYY-MM-DD`
  - move it to `<scope>/archive/`
  - rename with completion-date prefix: `YYYYMMDD-project-name.md`
- When a roadmap item is completed but never had a dedicated project write-up:
  - add it to `<scope>/archive/done.md`
  - use a dated section heading inside the file (for example: `## 2026-02-17`)

## Project write-ups

- A project can be a single Markdown file (for example: `<scope>/active/my-project.md`).
- Use a folder only when the project needs multiple files (images, notes, mockups).
- Folder entrypoint must be `<scope>/active/my-project/index.md`.
- Roadmap links should point to the single file or the folder entrypoint.

## Naming

- Use `kebab-case` for file and folder names.
- Use date prefixes for archived projects (`YYYYMMDD-project-name.md`).
- Exception: `archive/done.md` is a stable filename and is not date-prefixed.
- Keep links relative to the current folder, using `../` only when crossing scopes.

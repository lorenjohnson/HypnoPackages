# Docs Reorganization

**Created**: 2026-01-23
**Status**: Completed

## Overview

Reorganize the `docs/` directory to mirror the personal vault structure, making it easier to manage documentation across code projects and personal knowledge systems.

## Goals

- Align repo docs structure with personal vault conventions
- Use lowercase kebab-case folder names
- Flatten `_archive/` to just `archive/`
- Add `projects/backlog/` for planned-but-not-started work
- Create clear entry points (`index.md`) for each app
- Support agent-based documentation traversal

## Changes

### Structure

Before:
```text
docs/
├── Hypnograph/           # uppercase
│   ├── _archive/  # nested
│   └── projects/
├── Divine/
└── ontology/
```

After:
```text
docs/
├── hypnograph/           # lowercase
│   ├── archive/          # flattened
│   ├── projects/
│   │   └── backlog/      # new
│   └── index.md          # new entry point
├── divine/
│   ├── archive/
│   ├── projects/
│   │   └── backlog/
│   └── index.md
├── shared/               # new
│   └── ontology/
└── README.md
```

### Files Modified

- Renamed `docs/Hypnograph/` → `docs/hypnograph/`
- Renamed `docs/Divine/` → `docs/divine/`
- Moved `docs/ontology/` → `docs/shared/ontology/`
- Flattened `_archive/*` → `archive/*`
- Created `index.md` for hypnograph, divine, and shared
- Updated `docs/README.md` to reflect new structure
- Updated internal links to use new paths
- Added `**/.obsidian/` to `.gitignore`

## Related

- Vault system documentation: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Life/index.md`

# HypnoPackages

Shared Swift packages used by:

- [Hypnograph](https://github.com/lorenjohnson/Hypnograph)
- [Divine](https://github.com/lorenjohnson/Divine.git)

This repository is the common foundation for rendering, effects, media integration, and shared UI primitives used across both apps.

## What Is In This Repo

`HypnoPackages` is a Swift Package Manager workspace with two library products:

- `HypnoCore`
  - Core rendering pipeline (Metal-based composition, display, transitions)
  - Runtime effect system and effect-chain infrastructure
  - Media ingestion and Apple Photos integration hooks
  - Session/recipe models used by host applications
- `HypnoUI`
  - Shared AppKit/SwiftUI-adjacent UI helpers and cross-app UI utilities
  - Depends on `HypnoCore`

It also includes:

- `HypnoCoreTests` for core behavior validation
- `docs/` for shared architecture/backlog/archive notes across apps
- `scripts/` for utility scripts (for example, ontology generation)

## Repository Layout

```text
HypnoPackages/
  HypnoCore/        # Shared core engine, renderer, effects, models
  HypnoUI/          # Shared UI helpers/components
  HypnoCoreTests/   # Tests for HypnoCore
  docs/             # Shared cross-app documentation
  scripts/          # Utilities
  Package.swift
```

## Using HypnoPackages From An App

In your app project, add `HypnoPackages` as a Swift package dependency.

### Local development (recommended while co-developing)

Check out `Hypnograph`, `Divine`, and `HypnoPackages` side-by-side, then point the app to the local path of `HypnoPackages` in Xcode/SwiftPM.

### Git dependency

Use the repository URL:

- `https://github.com/lorenjohnson/HypnoPackages.git`

and pin to a tag/branch/commit appropriate for your app release cycle.

## Build And Test

From the repository root:

```bash
swift build
swift test
```

## Notes

- Minimum platform is macOS 14 (see `Package.swift`).
- Runtime effect assets and default effect manifests are packaged as target resources in `HypnoCore`.
- Changes here can affect both Hypnograph and Divine; treat API/behavior changes as shared-contract changes.

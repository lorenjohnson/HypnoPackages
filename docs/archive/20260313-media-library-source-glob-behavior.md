---
created: 2026-03-12
updated: 2026-03-13
status: completed
completed: 2026-03-13
---

# Media Library Source Glob Behavior

## Scope

This note documents how `HypnoCore/Media/MediaLibrary.swift` interprets folder paths and glob patterns in `sources`.

Because this behavior is in `HypnoCore`, it applies to both Hypnograph and Divine.

## Rules

- Literal file path:
  - index that file if extension + media type are supported.
- Literal directory path (no glob tokens):
  - index only direct children (non-recursive).
- Glob pattern:
  - glob matching is enabled by `*` / `?`.
  - recursion is implied only by `**`.
  - matched files are indexed directly.
  - matched directories are scanned for media files.
  - directory scanning is recursive only when `**` is present in the source pattern.

## Extension Allowlist

- After path/glob matching, candidate files are still filtered by hard-coded image/video extension allowlists.
- The allowlists are defined in code at [HypnoCore/Media/MediaLibrary.swift](../../HypnoCore/Media/MediaLibrary.swift) (`allowedPhotoExtensions` and `allowVideoExtensions`).
- If a pattern matches only unsupported extensions, indexing result is empty.

## Examples

- `/the-fault/*.mov`
  - only `.mov` files directly in `/the-fault`.
- `/the-fault/**/*.mov`
  - `.mov` files in `/the-fault` and all subfolders.
- `/the-fault/**/A Cam`
  - match directories named `A Cam` at any depth, then index media files from those matched directories.

## Matcher Note

- `**/` matches zero-or-more path components.
- This means `**/*.png` also matches base-level files.

## Related Code

- `HypnoCore/Media/MediaLibrary.swift`
- `HypnoCoreTests/MediaLibraryTests.swift`

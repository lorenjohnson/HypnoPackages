---
last_reviewed: 2026-03-13T00:00:00Z
---

# Media Library Architecture

## Scope
This document covers shared `HypnoCore` media-library behavior used by app hosts (including Hypnograph and Divine).

## Sources

- `HypnoCore/Media/MediaModels.swift` (MediaSource, MediaFile, VideoClip)
- `HypnoCore/Media/MediaLibrary.swift`
- `HypnoCore/Media/MediaLibraryBuilder.swift`
- `HypnoCore/Cache/PersistentIdentifierStore.swift` (ExclusionStore)
- `HypnoCore/Renderer/Core/SourceLoader.swift`
- `HypnoCore/Media/HypnoCoreHooks.swift`
- `HypnoCore/Media/ApplePhotosHooks.swift`
- `HypnoCore/Media/ApplePhotos.swift`
- `HypnoCore/Media/StillImageCache.swift`
- `HypnoCore/Recipes/HypnogramSource.swift`

## Core Data Types

### MediaSource

- Top-level enum representing where media comes from.
- Cases: `.url(URL)` for local files, `.external(identifier: String)` for external sources.
- External sources use opaque identifiers resolved via `HypnoCoreHooks`.
- Backwards-compatible decoding supports legacy `.photos` format.

### MediaFile

- Abstracts over file URLs and external asset identifiers.
- Contains `source: MediaSource`, `mediaKind`, `duration`, and `id`.
- Provides async loading helpers (`loadAsset`, `loadImage`, `loadCGImage`) that use `HypnoCoreHooks` to resolve external sources.

### VideoClip

- A clip is a `MediaFile` plus `startTime` and `duration`.

### HypnogramSource

- A recipe source: clip + transforms + blend mode + effect chain.

## MediaLibrary

### Indexing Model

- Builds a lightweight `sourceIndex` of `(source, mediaKind)` entries.
- Avoids eager AVAsset or metadata loading for faster startup.
- Supports filtering by `SourceMediaType` (images, videos).
- Deduplicates files by normalized path during indexing.

### Source Inputs

- Folder paths or single files.
- Glob patterns for file and directory matching.
- Apple Photos albums or the full Photos library.
- Custom Photos selection (explicit asset identifiers).
- If no explicit sources are provided, falls back to scanning the Photos originals directory on disk.

### Path and Glob Semantics

- Literal file path:
  - indexes that file if extension + media type are supported.
- Literal directory path (no glob tokens):
  - indexes only direct children (non-recursive).
- Glob pattern:
  - `*` and `?` enable glob matching.
  - recursion is syntax-driven by `**`.
  - matched files are indexed directly.
  - matched directories are scanned for media files.
  - matched directory scanning is recursive only when `**` is present in the source pattern.

Examples:

- `/the-fault/*.mov` -> direct files only.
- `/the-fault/**/*.mov` -> recursive file match.
- `/the-fault/**/A Cam` -> matches directories named `A Cam` at any depth, then indexes files from those directories.

Implementation note:

- `**/` is interpreted as zero-or-more path components, so patterns like `**/*.png` also match files in the base directory.

### Extension Filtering

- After path/glob expansion, indexing still applies hard-coded extension filtering for images/videos.
- This filtering happens in `HypnoCore` and is independent from the glob pattern shape.
- Current allowlists are defined in `HypnoCore/Media/MediaLibrary.swift` (`allowedPhotoExtensions` and `allowVideoExtensions`).
- If a pattern only matches unsupported file extensions, the effective result is an empty source set.

### Random Clip Selection

- `randomClip(clipLength:)` samples from `sourceIndex` and validates on demand.
- Nil clip length uses full video duration with a short default for images.
- Failed sources are tracked in-memory to avoid repeated attempts.
- Video sources get randomized clip start times within duration.
- Image sources create a short-duration `VideoClip` with `startTime = .zero`.

### Exclusions

- `applyExclusions()` filters out items in `ExclusionStore` and the Apple Photos "Hypnograph/Excluded" album.
- Photos hidden assets are filtered via `ApplePhotos.cachedHiddenUUIDs`.

## SourceLoader

- Loads `HypnogramSource` into `LoadedSource` for the renderer.
- Caches `LoadedSource` by file ID to avoid repeated AVAsset loads.
- Supports:
  - AVURLAsset for file URLs.
  - External sources via `HypnoCoreHooks.resolveExternalVideo` and `resolveExternalImage`.
- Converts metadata transforms to CIImage space inside the renderer pipeline.

## HypnoCoreHooks

- Generic hook system for decoupling HypnoCore from external source implementations.
- Apps configure `HypnoCoreHooks.shared` at startup to provide:
  - `resolveExternalVideo`: Resolves external identifier to AVAsset.
  - `resolveExternalImage`: Resolves external identifier to CIImage.
  - `onVideoExportCompleted`: Called when video export finishes (e.g., save to Photos).
  - `onImageExportCompleted`: Called when image export finishes.
- External identifiers are opaque strings; apps can encode routing info as needed.

## ApplePhotosHooks

- Convenience installer that wires `HypnoCoreHooks` to `ApplePhotos.shared`.
- Call `ApplePhotosHooks.install()` at app startup to enable Photos integration.
- Handles video/image resolution and auto-save to Photos on export.

## ApplePhotos

- Handles authorization and fetches PHAssets.
- Supports:
  - Loading AVAsset for videos.
  - Loading CIImage for still images.
  - Hidden asset caching for exclusion.
  - Album discovery for menu display.
  - Saving renders back to a "Hypnograms" album.

## StillImageCache

- Caches decoded still images to avoid repeated IO and decode errors.
- Always decodes via `CGImageSource` to prevent CIImage IOSurface issues.
- Cache is unbounded and must be cleared explicitly if needed.

## Persistence

- Exclusions persist via `HypnoCoreConfig.exclusionsURL`.

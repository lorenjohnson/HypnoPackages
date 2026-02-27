# Runtime Effects Runtime Contract Unification

**Created**: 2026-02-27
**Status**: Completed

## Overview

Standardize Metal runtime effects on a single runtime kind contract so app-side effect loading and rendering paths are simpler and less error-prone.

## Architectural Decision

- Use one Metal runtime kind: `runtimeKind: "metal"`.
- Remove `metalTemporal` as a distinct runtime kind.
- Represent temporal behavior via manifest bindings and lookback parameters, not runtime kind branching.
- Do not preserve backward compatibility for `metalTemporal`; manifests and consumers are expected to use the unified Metal kind.

## Changes

- Updated runtime manifests under `HypnoCore/Renderer/Effects/RuntimeAssets/*/effect.json` to the unified Metal runtime kind.
- Confirmed temporal effects continue to declare required history/lookback inputs through manifest data.
- Removed repo/runtime references that treated temporal Metal effects as a separate runtime kind path.

## Impact

- Effect consumers (including Hypnograph Effects Studio) now rely on one Metal runtime classification.
- Runtime loading and filtering logic is simpler because Metal effects no longer split across two kinds.
- Future runtime effect additions use one manifest kind contract regardless of whether the effect is temporal.

## Verification

- Temporal runtime effects (including Ghost Blur, Color Echo, Frame Difference, I-Frame Compress, Posterize Decay) were validated against the unified manifest contract.
- Hypnograph render/test verification completed after unification with no regressions attributed to runtime kind changes.

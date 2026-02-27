# Basic Color Space Visualization Mode

**Created**: 2026-02-27
**Status**: Backlog

## Context

`RuntimeAssets/945ed25c-c2df-4170-a720-00755847b2d0/shader.metal` currently treats `colorSpace` as the working space for adjustments and converts back to RGB for output.

With neutral sliders (`contrast`, `brightness`, `saturation`, `hueShift` at defaults), changing `colorSpace` is near-no-op.

## Bookmark

An experimental variant was tested where final output was converted to the selected color space representation before writing the pixel. This produced stronger visual changes in Studio and was subjectively preferred in quick testing.

## Follow-up Option

Add an explicit mode toggle so behavior is intentional:

- `processing` (current accurate behavior): convert to working space, apply adjustments, convert back to RGB output.
- `visualize` (experimental): keep processing flow, then convert final RGB to selected color-space representation for display output.

This avoids ambiguity between "math space" and "display space" semantics.

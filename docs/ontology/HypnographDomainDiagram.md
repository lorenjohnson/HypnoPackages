# Hypnograph Domain Diagram (Curated)

This is a curated, naming-oriented view of the core domain entities (media → recipe → render).

For the full, generated graph of *all* discovered Swift types and relationships, see:

- `docs/ontology/hypnograph-ontology.mmd` (filtered)
- `docs/ontology/hypnograph-ontology-full.mmd` (full)
- `docs/ontology/types.json` (machine-readable)

```mermaid
graph TD
  %% Media models (origin of bytes)
  MediaSource["HypnoCore.MediaSource<br/>(url | external)"]
  MediaFile["HypnoCore.MediaFile<br/>(selectable asset)"]
  MediaClip["HypnoCore.MediaClip<br/>(media slice of MediaFile)"]

  %% Recipe models (what to render)
  HypnogramLayer["HypnoCore.HypnogramLayer<br/>(LAYER: media slice + transforms + blend + effects)"]
  Hypnogram["HypnoCore.Hypnogram<br/>(CLIP (sequence item): layers + composition effects + duration)"]
  HypnographSession["HypnoCore.HypnographSession<br/>(SESSION: ordered hypnograms + snapshot)"]
  EffectChain["HypnoCore.EffectChain"]

  %% Renderer pipeline (how it renders)
  SourceLoader["HypnoCore.SourceLoader"]
  LoadedSource["HypnoCore.LoadedSource<br/>(AVAsset/CIImage + metadata)"]
  CompositionBuilder["HypnoCore.CompositionBuilder"]
  RenderEngine["HypnoCore.RenderEngine"]

  %% App state (who owns recipes)
  Dream["Hypnograph.Dream"]

  MediaSource -->|backs| MediaFile
  MediaFile -->|sliced by| MediaClip

  MediaClip -->|is the clip of| HypnogramLayer
  HypnogramLayer -->|per-layer| EffectChain
  Hypnogram -->|contains many| HypnogramLayer
  Hypnogram -->|composition| EffectChain
  HypnographSession -->|contains many| Hypnogram

  HypnogramLayer -->|loaded by| SourceLoader
  SourceLoader -->|produces| LoadedSource
  Hypnogram -->|built by| CompositionBuilder
  CompositionBuilder -->|uses| SourceLoader
  RenderEngine -->|drives| CompositionBuilder

  Dream -->|owns| HypnographSession
```

## Vocabulary summary

Core domain nouns (implemented 2026-01-22):

- **HypnographSession** = sequence/container of playable items
- **Hypnogram** = one playable item (1..N layers)
- **HypnogramLayer** = one layer inside a hypnogram
- **MediaClip** = a time slice of a selected media asset

```mermaid
graph TD
  %% Media models
  MediaSource["MediaSource"]
  MediaFile["MediaFile"]
  MediaClip["MediaClip"]

  %% Composition models
  HypnogramLayer["HypnogramLayer"]
  Hypnogram["Hypnogram"]
  HypnographSession["HypnographSession"]

  MediaSource --> MediaFile
  MediaFile --> MediaClip

  MediaClip --> HypnogramLayer
  Hypnogram -->|contains many| HypnogramLayer
  HypnographSession -->|contains many| Hypnogram
```

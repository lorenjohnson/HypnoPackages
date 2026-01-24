# Hypnograph Ontology (Generated)

This folder contains a best-effort ontology of the Swift types in this repo, plus Mermaid diagrams.

## Generate / refresh

From the repo root:

```sh
python3 scripts/generate_ontology.py
```

Outputs:

- `docs/shared/ontology/types.json`: All discovered types + internal relationships (best-effort).
- `docs/shared/ontology/naming.json`: Quick naming-oriented slices (e.g., `*Source`, `*Loader`).
- `docs/shared/ontology/hypnograph-ontology.mmd`: Filtered Mermaid graph for readability.
- `docs/shared/ontology/hypnograph-ontology-full.mmd`: Full Mermaid graph (can be very large).
- `docs/shared/ontology/HypnographDomainDiagram.md`: Curated domain diagram for naming/consistency checks.
- `docs/hypnograph/archive/20260121-more-clear-naming/overview.md`: Naming cleanup planning notes.

## Viewing diagrams

Mermaid is supported by many Markdown editors and plugins, and also by `mmdc` if you have it installed.

Tip: the full graph is often easiest to inspect by searching within it (type name) rather than trying to render it all at once.

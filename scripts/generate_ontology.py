#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Iterable


TYPE_DECL_RE = re.compile(
    r"(?m)^\s*(?:public|internal|open|fileprivate|private)?\s*(?:final\s+)?"
    r"(class|struct|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)\b([^{\n]*)"
)
EXT_DECL_RE = re.compile(
    r"(?m)^\s*(?:public|internal|open|fileprivate|private)?\s*"
    r"extension\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\b([^{\n]*)"
)
IMPORT_RE = re.compile(r"(?m)^\s*import\s+([A-Za-z0-9_\.]+)\s*$")
CAP_TYPE_TOKEN_RE = re.compile(r"\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\b")
IGNORED_TYPE_NAMES = {"CodingKeys"}


def _strip_generics(s: str) -> str:
    # Best-effort: remove single-level generic parameter lists.
    # This is intentionally conservative to avoid over-stripping.
    return re.sub(r"<[^>\n]*>", "", s)


def _split_bases(s: str | None) -> list[str]:
    if not s:
        return []
    if ":" not in s:
        return []
    bases_part = s.split(":", 1)[1]
    bases_part = bases_part.split("where", 1)[0]
    items = []
    for raw in bases_part.split(","):
        item = raw.strip()
        if not item:
            continue
        item = _strip_generics(item)
        item = re.sub(r"^\s*(any|some)\s+", "", item)
        item = re.sub(r"^\s*@\w+\s+", "", item)
        item = item.strip()
        if not item:
            continue
        items.append(item)
    return items


def _module_for_path(repo_root: Path, file_path: Path) -> str:
    try:
        rel = file_path.relative_to(repo_root)
    except ValueError:
        return "Unknown"
    parts = rel.parts
    return parts[0] if parts else "Unknown"


def _find_matching_brace_span(text: str, start_idx: int) -> tuple[int, int] | None:
    open_idx = text.find("{", start_idx)
    if open_idx == -1:
        return None
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return (open_idx, i)
        i += 1
    return None


def _strip_swift_comments(text: str) -> str:
    # Best-effort: remove block and line comments to reduce false-positive tokens.
    # This is not a full lexer (strings may still contain comment-like sequences).
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"//.*?$", "", text, flags=re.MULTILINE)
    return text


def _safe_node_id(type_key: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]", "_", type_key)


@dataclass
class TypeInfo:
    key: str
    name: str
    qualified_name: str
    module: str
    kind: str
    file: str
    imports: list[str] = field(default_factory=list)
    conforms_raw: list[str] = field(default_factory=list)
    conforms_internal: list[str] = field(default_factory=list)
    uses_internal: list[str] = field(default_factory=list)


def _iter_swift_files(repo_root: Path, roots: Iterable[str], include_tests: bool) -> list[Path]:
    excluded_dir_prefixes = (
        ".git",
        ".derivedData",
        "DerivedData",
        "build",
        ".build",
        ".swiftpm",
        "agent-os",
        "agents",
    )
    files: list[Path] = []
    for root in roots:
        root_path = repo_root / root
        if not root_path.exists():
            continue
        for path in root_path.rglob("*.swift"):
            rel = path.relative_to(repo_root)
            if any(part.startswith(excluded_dir_prefixes) for part in rel.parts):
                continue
            if not include_tests and any(part.endswith("Tests") or part.endswith("UITests") for part in rel.parts):
                continue
            files.append(path)
    return sorted(files)


def _resolve_ref(
    current_key: str, current_module: str, name_to_keys: dict[str, list[str]], ref_name: str
) -> str | None:
    candidates = name_to_keys.get(ref_name)
    if not candidates:
        return None
    candidate_set = set(candidates)

    # Prefer nested types in the current lexical chain:
    # e.g. for `HypnoCore.RenderEngine`, resolve `Config` to `HypnoCore.RenderEngine.Config` if present.
    parts = current_key.split(".")
    for i in range(len(parts), 1, -1):
        prefix = ".".join(parts[:i])
        target = f"{prefix}.{ref_name}"
        if target in candidate_set:
            return target

    # Fall back to unique candidate (possibly in another module).
    if len(candidates) == 1:
        return candidates[0]

    # If still ambiguous, prefer same-module top-level type.
    same_module = [c for c in candidates if c.startswith(current_module + ".")]
    if len(same_module) == 1:
        return same_module[0]

    # Ambiguous; don't guess.
    return None


def build_ontology(repo_root: Path, roots: list[str], include_tests: bool) -> dict:
    swift_files = _iter_swift_files(repo_root, roots, include_tests=include_tests)

    name_to_keys: dict[str, list[str]] = {}
    types: dict[str, TypeInfo] = {}
    body_spans: dict[str, tuple[Path, int, int]] = {}

    @dataclass
    class _Decl:
        kind: str
        name: str
        rest: str
        decl_end: int
        open_idx: int
        close_idx: int
        qualified_name: str = ""

    # Pass 1: collect declared types + imports + raw bases.
    for path in swift_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        imports = sorted(set(IMPORT_RE.findall(text)))
        module = _module_for_path(repo_root, path)

        decls: list[_Decl] = []
        for m in TYPE_DECL_RE.finditer(text):
            kind, name, rest = m.group(1), m.group(2), (m.group(3) or "")
            if name in IGNORED_TYPE_NAMES:
                continue
            brace_span = _find_matching_brace_span(text, m.end())
            if brace_span is None:
                open_idx, close_idx = -1, -1
            else:
                open_idx, close_idx = brace_span
            decls.append(
                _Decl(
                    kind=kind,
                    name=name,
                    rest=rest,
                    decl_end=m.end(),
                    open_idx=open_idx,
                    close_idx=close_idx,
                )
            )

        # Determine nesting by brace ranges (best-effort).
        decls_sorted = sorted(
            [d for d in decls if d.open_idx >= 0 and d.close_idx >= 0],
            key=lambda d: (d.open_idx, -(d.close_idx - d.open_idx)),
        )
        stack: list[_Decl] = []
        for d in decls_sorted:
            while stack and d.open_idx > stack[-1].close_idx:
                stack.pop()
            parent = stack[-1] if stack and d.open_idx > stack[-1].open_idx and d.close_idx <= stack[-1].close_idx else None
            if parent and parent.qualified_name:
                d.qualified_name = f"{parent.qualified_name}.{d.name}"
            else:
                d.qualified_name = d.name
            stack.append(d)

        # Any decls without a body span are treated as top-level (protocols can still have braces, but best-effort).
        for d in decls:
            if not d.qualified_name:
                d.qualified_name = d.name

            key = f"{module}.{d.qualified_name}"
            if key in types:
                # Multiple declarations with identical qualified names in the same module are unusual; keep first.
                continue

            conforms_raw = _split_bases(d.rest)
            types[key] = TypeInfo(
                key=key,
                name=d.name,
                qualified_name=d.qualified_name,
                module=module,
                kind=d.kind,
                file=str(path.relative_to(repo_root)),
                imports=imports,
                conforms_raw=conforms_raw,
            )
            name_to_keys.setdefault(d.name, []).append(key)
            if d.open_idx >= 0 and d.close_idx >= 0:
                body_spans[key] = (path, d.open_idx, d.close_idx)

        for m in EXT_DECL_RE.finditer(text):
            ext_name = m.group(1)
            name = ext_name.split(".")[-1]
            if name in IGNORED_TYPE_NAMES:
                continue
            rest = m.group(2) or ""
            conforms_raw = _split_bases(rest)
            key = f"{module}.{ext_name}"
            if key not in types:
                # Extension for a type declared elsewhere in another module is not legal in Swift,
                # but tests and tooling files may contain stubs; record anyway.
                types[key] = TypeInfo(
                    key=key,
                    name=name,
                    qualified_name=ext_name,
                    module=module,
                    kind="extension",
                    file=str(path.relative_to(repo_root)),
                    imports=imports,
                    conforms_raw=[],
                )
                name_to_keys.setdefault(name, []).append(key)
            types[key].conforms_raw = sorted(set(types[key].conforms_raw + conforms_raw))

    # Resolve internal conformances.
    for t in types.values():
        resolved: set[str] = set()
        for raw in t.conforms_raw:
            token = raw.split(".")[-1]
            token = re.sub(r"[^A-Za-z0-9_]", "", token)
            if not token:
                continue
            r = _resolve_ref(t.key, t.module, name_to_keys, token)
            if r:
                resolved.add(r)
        t.conforms_internal = sorted(resolved)

    internal_names = set(name_to_keys.keys())

    # Pass 2: best-effort "uses" edges by scanning each type body for internal type tokens.
    for key, (path, open_idx, close_idx) in body_spans.items():
        text = path.read_text(encoding="utf-8", errors="replace")
        body_text = _strip_swift_comments(text[open_idx : close_idx + 1])
        current_module = types[key].module

        used: set[str] = set()
        for token in CAP_TYPE_TOKEN_RE.findall(body_text):
            base = token.split(".")[-1]
            if base in IGNORED_TYPE_NAMES:
                continue
            if base == types[key].name:
                continue
            if base not in internal_names:
                continue
            resolved = _resolve_ref(key, current_module, name_to_keys, base)
            if resolved and resolved != key:
                used.add(resolved)
        types[key].uses_internal = sorted(used)

    # Reverse edges for analysis.
    used_by: dict[str, set[str]] = {k: set() for k in types.keys()}
    conformed_by: dict[str, set[str]] = {k: set() for k in types.keys()}
    for t in types.values():
        for u in t.uses_internal:
            used_by.setdefault(u, set()).add(t.key)
        for c in t.conforms_internal:
            conformed_by.setdefault(c, set()).add(t.key)

    return {
        "repo_root": str(repo_root),
        "roots": roots,
        "include_tests": include_tests,
        "type_count": len(types),
        "types": [asdict(t) for t in sorted(types.values(), key=lambda x: x.key)],
        "used_by": {k: sorted(v) for k, v in used_by.items() if v},
        "conformed_by": {k: sorted(v) for k, v in conformed_by.items() if v},
    }


def _write_mermaid(
    out_path: Path,
    ontology: dict,
    *,
    max_nodes_per_module: int | None,
    min_degree: int = 0,
    include_extension_nodes: bool = True,
) -> None:
    types = {t["key"]: t for t in ontology["types"]}

    used_by = {k: set(v) for k, v in ontology.get("used_by", {}).items()}
    conformed_by = {k: set(v) for k, v in ontology.get("conformed_by", {}).items()}

    degree: dict[str, int] = {}
    for key, t in types.items():
        uses = set(t.get("uses_internal", []))
        conforms = set(t.get("conforms_internal", []))
        degree[key] = (
            len(uses)
            + len(used_by.get(key, set()))
            + len(conforms)
            + len(conformed_by.get(key, set()))
        )

    modules: dict[str, list[str]] = {}
    for key, t in types.items():
        if not include_extension_nodes and t.get("kind") == "extension":
            continue
        if degree[key] < min_degree:
            continue
        modules.setdefault(t["module"], []).append(key)

    selected: set[str] = set()
    for module, keys in modules.items():
        keys_sorted = sorted(keys, key=lambda k: (-degree[k], k))
        if max_nodes_per_module is not None:
            keys_sorted = keys_sorted[:max_nodes_per_module]
        selected.update(keys_sorted)
        modules[module] = keys_sorted

    lines: list[str] = []
    lines.append("graph TB")
    lines.append("%% Generated by scripts/generate_ontology.py")
    lines.append("")

    for module in sorted(modules.keys()):
        lines.append(f"subgraph {module}")
        for key in modules[module]:
            node_id = _safe_node_id(key)
            label = types[key].get("qualified_name") or types[key]["name"]
            kind = types[key]["kind"]
            lines.append(f'  {node_id}["{label} ({kind})"]')
        lines.append("end")
        lines.append("")

    def emit_edge(a: str, b: str, style: str) -> None:
        if a not in selected or b not in selected:
            return
        a_id = _safe_node_id(a)
        b_id = _safe_node_id(b)
        lines.append(f"  {a_id} {style} {b_id}")

    # Uses: solid arrow
    for key, t in types.items():
        for u in t.get("uses_internal", []):
            emit_edge(key, u, "-->")

    lines.append("")
    # Conformance/inheritance: dotted arrow with label
    for key, t in types.items():
        for c in t.get("conforms_internal", []):
            emit_edge(key, c, "-. conforms .->")

    out_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def _naming_report(ontology: dict) -> dict:
    types = ontology["types"]

    def by_suffix(suffix: str) -> list[dict]:
        return sorted([t for t in types if t["name"].endswith(suffix)], key=lambda x: x["key"])

    def by_prefix(prefix: str) -> list[dict]:
        return sorted([t for t in types if t["name"].startswith(prefix)], key=lambda x: x["key"])

    def by_contains(substr: str) -> list[dict]:
        return sorted([t for t in types if substr in t["name"]], key=lambda x: x["key"])

    def duplicates() -> dict:
        from collections import defaultdict

        name_to_keys: dict[str, list[str]] = defaultdict(list)
        for t in types:
            name_to_keys[t["name"]].append(t["key"])

        excluded = {"CodingKeys"}
        out: dict[str, list[str]] = {}
        for name, keys in name_to_keys.items():
            if name in excluded:
                continue
            if len(keys) > 1:
                out[name] = sorted(keys)
        return dict(sorted(out.items(), key=lambda x: (-len(x[1]), x[0])))

    def base_variants() -> dict:
        from collections import defaultdict

        suffixes = [
            "Source",
            "Clip",
            "Recipe",
            "Engine",
            "Builder",
            "Loader",
            "Manager",
            "Session",
            "Store",
            "View",
            "Config",
            "State",
            "Hook",
        ]
        base_to_variants: dict[str, set[str]] = defaultdict(set)
        for t in types:
            name = t["name"]
            base = None
            for s in suffixes:
                if name.endswith(s) and name != s:
                    base = name[: -len(s)]
                    break
            if base and base != name:
                base_to_variants[base].add(name)

        out: dict[str, list[str]] = {}
        for base, variants in base_to_variants.items():
            if len(variants) >= 2:
                out[base] = sorted(variants)
        return dict(sorted(out.items(), key=lambda x: (-len(x[1]), x[0])))

    return {
        "by_suffix": {
            "Source": by_suffix("Source"),
            "Clip": by_suffix("Clip"),
            "Recipe": by_suffix("Recipe"),
            "Engine": by_suffix("Engine"),
            "Builder": by_suffix("Builder"),
            "Loader": by_suffix("Loader"),
            "Manager": by_suffix("Manager"),
            "Session": by_suffix("Session"),
            "Store": by_suffix("Store"),
            "View": by_suffix("View"),
            "Config": by_suffix("Config"),
            "State": by_suffix("State"),
            "Hook": by_suffix("Hook"),
        },
        "by_prefix": {
            "Media": by_prefix("Media"),
            "Hypnogram": by_prefix("Hypnogram"),
            "Render": by_prefix("Render"),
            "Effect": by_prefix("Effect"),
            "Dream": by_prefix("Dream"),
            "Player": by_prefix("Player"),
        },
        "by_contains": {
            "Source": by_contains("Source"),
            "Clip": by_contains("Clip"),
            "Renderer": by_contains("Renderer"),
            "Effect": by_contains("Effect"),
        },
        "duplicates": duplicates(),
        "base_variants": base_variants(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a best-effort type ontology for Hypnograph.")
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repository root (default: current directory).",
    )
    parser.add_argument(
        "--roots",
        nargs="*",
        default=["HypnoCore", "HypnoUI", "HypnogramQuickLook", "Hypnograph", "Divine"],
        help="Top-level directories to scan.",
    )
    parser.add_argument(
        "--include-tests",
        action="store_true",
        help="Include test targets (Tests/UITests).",
    )
    parser.add_argument(
        "--out-dir",
        default="docs/ontology",
        help="Output directory (default: docs/ontology).",
    )
    parser.add_argument(
        "--top-per-module",
        type=int,
        default=25,
        help="Max nodes per module for the readable diagram (default: 25). Use 0 for unlimited.",
    )
    parser.add_argument(
        "--min-degree",
        type=int,
        default=2,
        help="Minimum (approx) degree for readable diagram (default: 2).",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    out_dir = (repo_root / args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    ontology = build_ontology(repo_root, roots=args.roots, include_tests=args.include_tests)
    (out_dir / "types.json").write_text(json.dumps(ontology, indent=2), encoding="utf-8")

    naming = _naming_report(ontology)
    (out_dir / "naming.json").write_text(json.dumps(naming, indent=2), encoding="utf-8")

    # Readable diagram (filtered)
    top_per_module = None if args.top_per_module == 0 else args.top_per_module
    _write_mermaid(
        out_dir / "hypnograph-ontology.mmd",
        ontology,
        max_nodes_per_module=top_per_module,
        min_degree=args.min_degree,
        include_extension_nodes=False,
    )

    # Full diagram (can be huge)
    _write_mermaid(
        out_dir / "hypnograph-ontology-full.mmd",
        ontology,
        max_nodes_per_module=None,
        min_degree=0,
        include_extension_nodes=True,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

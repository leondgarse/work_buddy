"""Requirement dossiers: requirements/<ID>/{meta.yaml, context.md, timeline.md, sources/}."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

import yaml

REQ_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

META_TEMPLATE = """\
id: {id}
title: {title}
status: active
# Linking rules: an item is linked automatically when it mentions the id, or matches below.
aliases: {aliases}     # names/keywords for this requirement (English matched as whole words, CJK as substrings)
people: []             # emails or Lark names; only strengthens other matches
lark_chats: []         # chat ids (oc_...) dedicated to this requirement: every message links
lark_docs: []          # doc/wiki URLs or tokens: synced, and messages that link them are linked
email_threads: []      # Message-IDs of thread roots
repos: {{}}              # {{~/path/to/repo: [src/feature/, docs/feature.md]}}; empty list = whole repo
"""

CONTEXT_TEMPLATE = """\
# {id} — {title}

_Last updated: never. Every bullet cites a file under sources/._

## Goal

## Scope
- In:
- Out:

## Decisions

## Open questions

## Owners & action items

## Risks & dependencies

## Superseded
"""

TIMELINE_TEMPLATE = """\
# {id} timeline

<!-- One line per event, oldest first: - YYYY-MM-DD [source] what happened (sources/<file>) -->
"""


@dataclass
class Requirement:
    id: str
    dir: Path
    meta: dict

    @property
    def title(self) -> str:
        return self.meta.get("title") or ""

    def list(self, key: str) -> list:
        value = self.meta.get(key) or []
        return [str(v) for v in value] if isinstance(value, list) else [str(value)]


def req_dir(root: Path, req_id: str) -> Path:
    return root / "requirements" / req_id


def create(root: Path, req_id: str, title: str, aliases: list[str] | None = None) -> Requirement:
    if not REQ_ID.match(req_id):
        raise ValueError(f"invalid requirement id {req_id!r}: use letters, digits, '.', '_' or '-'")
    d = req_dir(root, req_id)
    if (d / "meta.yaml").exists():
        raise ValueError(f"requirement {req_id} already exists at {d}")
    (d / "sources").mkdir(parents=True, exist_ok=True)
    fields = {"id": json.dumps(req_id), "title": json.dumps(title, ensure_ascii=False)}
    (d / "meta.yaml").write_text(
        META_TEMPLATE.format(**fields, aliases=json.dumps(aliases or [], ensure_ascii=False))
    )
    (d / "context.md").write_text(CONTEXT_TEMPLATE.format(id=req_id, title=title))
    (d / "timeline.md").write_text(TIMELINE_TEMPLATE.format(id=req_id))
    return load(root, req_id)


def load(root: Path, req_id: str) -> Requirement:
    d = req_dir(root, req_id)
    path = d / "meta.yaml"
    if not path.exists():
        raise KeyError(f"no requirement {req_id} (expected {path})")
    meta = yaml.safe_load(path.read_text()) or {}
    return Requirement(id=req_id, dir=d, meta=meta)


def load_all(root: Path, include_closed: bool = True) -> list[Requirement]:
    base = root / "requirements"
    if not base.exists():
        return []
    reqs = [load(root, p.parent.name) for p in sorted(base.glob("*/meta.yaml"))]
    if not include_closed:
        reqs = [r for r in reqs if r.meta.get("status", "active") != "closed"]
    return reqs

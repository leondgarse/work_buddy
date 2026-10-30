"""Rule-based linking of items to requirements. Confident matches link automatically; the rest
go to the inbox with suggestions, for the agent (or you) to triage."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from .dossier import Requirement
from .model import Item
from .store import Store

AUTO_LINK = 0.6
SUGGEST = 0.2

_DOC_URL = re.compile(r"https?://[\w.-]+/(?:docx|docs|wiki|sheets|base|mindnotes)/([A-Za-z0-9]{8,})")


def doc_token(ref: str) -> str:
    """Token from a Lark doc/wiki URL, or the ref itself if it is already a token."""
    m = _DOC_URL.search(ref)
    return m.group(1) if m else ref.strip()


def doc_tokens_in(text: str) -> list[str]:
    return list(dict.fromkeys(_DOC_URL.findall(text)))


def _contains(text_lower: str, alias: str) -> bool:
    alias = alias.lower().strip()
    if not alias:
        return False
    if alias.isascii():
        return re.search(rf"(?<![\w-]){re.escape(alias)}(?![\w-])", text_lower) is not None
    return alias in text_lower


def _norm_thread(ref: str) -> str:
    return ref if ref.startswith("email:") else "email:" + ref.strip().strip("<>")


@dataclass
class Match:
    req_id: str
    score: float = 0.0
    reasons: list[str] = field(default_factory=list)

    def hit(self, score: float, reason: str) -> None:
        self.score = max(self.score, score)
        self.reasons.append(reason)


def score(item: Item, req: Requirement, thread_reqs: set[str]) -> Match:
    m = Match(req.id)
    text_lower = item.text.lower()

    if re.search(rf"(?<![\w-]){re.escape(req.id)}(?![\w-])", item.text, re.IGNORECASE):
        m.hit(1.0, "id")
    if req.id in thread_reqs:
        m.hit(0.9, "thread")
    if item.thread and item.thread in {_norm_thread(t) for t in req.list("email_threads")}:
        m.hit(1.0, "email-thread")

    chat = item.refs.get("chat")
    if chat and chat in req.list("lark_chats"):
        m.hit(1.0, "chat")

    req_docs = {doc_token(d) for d in req.list("lark_docs")}
    if req_docs & set(item.refs.get("docs", [])):
        m.hit(1.0 if item.source == "lark_doc" else 0.9, "doc")

    repo = item.refs.get("repo")
    if repo:
        for rpath, prefixes in (req.meta.get("repos") or {}).items():
            if str(Path(rpath).expanduser().resolve()) != repo:
                continue
            prefixes = [p.removeprefix("./").lstrip("/") for p in (prefixes or [])]
            if not prefixes:
                m.hit(0.9, "repo")
            elif any(p.startswith(pre) for p in item.refs.get("paths", []) for pre in prefixes):
                m.hit(0.9, "path")

    aliases = [a for a in req.list("aliases") if _contains(text_lower, a)]
    if aliases:
        in_title = any(_contains(item.title.lower(), a) for a in aliases)
        m.hit(0.8 if len(aliases) >= 2 else 0.7 if in_title else 0.5, "alias:" + "|".join(aliases))

    people = {p.lower() for p in req.list("people")}
    involved = {p.lower() for p in item.participants} | {item.author.lower()}
    if people & involved or any(p in item.author.lower() for p in people if p):
        m.score = min(1.0, m.score + 0.1) if m.score else SUGGEST
        m.reasons.append("people")
    return m


def link_item(store: Store, item: Item, reqs: list[Requirement]) -> list[str]:
    """Link item to every requirement it confidently matches. Weaker candidates go to the inbox for
    triage; items matching nothing are only indexed (still found by `wb search`)."""
    thread_reqs = store.reqs_for_thread(item.thread, exclude=item.id) if item.thread else set()
    matches = sorted((score(item, r, thread_reqs) for r in reqs), key=lambda m: -m.score)
    linked = []
    for m in matches:
        if m.score >= AUTO_LINK and store.link(item.id, m.req_id, "auto:" + ",".join(m.reasons), m.score):
            linked.append(m.req_id)
    suggestions = [{"req": m.req_id, "score": round(m.score, 2), "why": m.reasons}
                   for m in matches if SUGGEST <= m.score < AUTO_LINK][:3]
    if suggestions and not store.links_for(item.id):
        store.to_inbox(item.id, suggestions)
    return linked

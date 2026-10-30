"""The normalized item every source produces."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

import yaml


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@dataclass
class Item:
    id: str  # globally unique and stable, e.g. "email:<message-id>"
    source: str  # email | lark_msg | lark_doc | git | meeting
    title: str
    body: str
    ts: str  # ISO 8601
    author: str = ""
    url: str = ""
    participants: list[str] = field(default_factory=list)
    # Source-specific keys used for linking: chat, docs, repo, paths.
    refs: dict = field(default_factory=dict)
    revision: str = ""
    thread: str = ""  # items sharing a thread inherit each other's requirement links

    @property
    def text(self) -> str:
        return f"{self.title}\n{self.body}"

    def content_hash(self) -> str:
        h = hashlib.sha256()
        for part in (self.title, self.body, self.revision):
            h.update(part.encode())
            h.update(b"\0")
        return h.hexdigest()

    def file_stem(self) -> str:
        slug = re.sub(r"[^\w.-]+", "-", self.title).strip("-.")[:40] or "untitled"
        return f"{self.ts[:10]}_{slug}_{hashlib.sha1(self.id.encode()).hexdigest()[:8]}"

    def to_markdown(self) -> str:
        front = {
            "id": self.id,
            "source": self.source,
            "title": self.title,
            "author": self.author,
            "ts": self.ts,
            "url": self.url,
            "participants": self.participants,
            "refs": self.refs,
            "revision": self.revision,
        }
        front = {k: v for k, v in front.items() if v}
        header = yaml.safe_dump(front, allow_unicode=True, sort_keys=False)
        return f"---\n{header}---\n\n# {self.title}\n\n{self.body.strip()}\n"

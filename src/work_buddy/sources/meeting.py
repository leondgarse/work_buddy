"""Meeting transcripts and notes from local folders (.txt .md .vtt .srt). Also used by `wb add`."""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone
from pathlib import Path

from ..model import Item
from . import NotConfigured

EXTENSIONS = {".txt", ".md", ".vtt", ".srt"}
_CUE_TIME = re.compile(r"^\d{1,2}:\d{2}(:\d{2})?[.,]\d{1,3}\s*-->")
_VOICE = re.compile(r"^<v\s+([^>]+)>(.*?)(</v>)?$")
_DATE = re.compile(r"(\d{4})[-_.]?(\d{2})[-_.]?(\d{2})")


def clean_subtitles(text: str) -> str:
    """Turn WebVTT/SRT cues into 'Speaker: line' text, dropping timings and repeated lines."""
    out: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line == "WEBVTT" or line.isdigit() or _CUE_TIME.match(line) or line.startswith("NOTE"):
            continue
        m = _VOICE.match(line)
        if m:
            line = f"{m.group(1).strip()}: {m.group(2).strip()}"
        line = re.sub(r"</?[^>]+>", "", line)
        if not out or out[-1] != line:
            out.append(line)
    return "\n".join(out)


def parse_file(path: Path, source: str = "meeting") -> Item:
    path = path.expanduser().resolve()
    text = path.read_text(errors="replace")
    if path.suffix.lower() in {".vtt", ".srt"}:
        text = clean_subtitles(text)
    heading = re.search(r"^#\s+(.+)$", text, re.MULTILINE)
    title = heading.group(1).strip() if heading else path.stem
    m = _DATE.search(path.name)
    try:
        ts = datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)), tzinfo=timezone.utc) if m else None
    except ValueError:
        ts = None
    ts = ts or datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
    return Item(
        id=f"{source}:{hashlib.sha1(str(path).encode()).hexdigest()[:16]}",
        source=source,
        title=title,
        body=text,
        ts=ts.isoformat(timespec="seconds"),
        url=path.as_uri(),
        refs={"file": str(path)},
    )


def fetch(cfg: dict, store, reqs):
    dirs = (cfg.get("meetings") or {}).get("dirs") or []
    if not dirs:
        raise NotConfigured
    for d in dirs:
        for path in sorted(Path(d).expanduser().rglob("*")):
            if path.is_file() and path.suffix.lower() in EXTENSIONS:
                yield parse_file(path)

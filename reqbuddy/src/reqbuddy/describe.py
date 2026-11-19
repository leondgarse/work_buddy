"""Pictures to text, for a brief model that cannot see images: a vision model transcribes each picture.

The transcript takes the picture's place in the user message, so a text-only model (or a stronger text model
paired with a small local vision one) still gets the screenshots' values and which parts are marked.
"""
from __future__ import annotations

import re
from typing import Callable

from .config import Config, Provider
from .extract import Picture
from .llm import Client
from .prompt import jpeg_data_url

TRANSCRIBE_PROMPT = """Transcribe this image for someone who cannot see it.
- Copy all text exactly, in its original language. Keep numbers, codes and punctuation as shown.
- Tables: Markdown tables with the same columns and rows. Forms and key/value panels: one "Label: value" per line.
- Say what kind of image it is in one line first (e.g. "Screenshot of a web app modal titled …", "Scanned purchase order page").
- Annotations matter most. Only for something a person drew on top of the image (a hand-drawn or red rectangle, circle, arrow, underline or highlighter stroke), write [MARKED: <the exact text it surrounds or points at>] where it is. Part of the app's own design (status badges such as Match/Mismatch, coloured labels, headers, buttons) is NOT marked: give its text plainly. Most images have no annotations; then write no [MARKED].
- No commentary, no summary, no guesses about meaning."""


def parse_spec(cfg: Config, spec: str) -> Provider:
    """'provider name[|model]' -> a copy of that provider, with the model replaced when given."""
    name, _, model = spec.partition("|")
    base = cfg.provider(name.strip())
    p = Provider(**{**base.__dict__, "extra": {**(base.extra or {})}})
    if model.strip():
        p.model = model.strip()
    p.extra.setdefault("temperature", 0.0)
    p.extra.setdefault("max_tokens", 3000)   # a looping small model stops here
    return p


def transcriber(provider: Provider, image_side: int = 1600,
                progress: Callable[[str], None] | None = None) -> Callable[[Picture, str], str]:
    client = Client(provider)

    def run(pic: Picture, where: str) -> str:
        if progress:
            progress(f"transcribing {where} with {provider.model}")
        url, _ = jpeg_data_url(pic.data, image_side)
        msg = [{"role": "user", "content": [{"type": "text", "text": TRANSCRIBE_PROMPT},
                                             {"type": "image_url", "image_url": {"url": url}}]}]
        return drop_repeats(client.complete(msg))
    return run


def drop_repeats(text: str, max_same: int = 3) -> str:
    """Cut a greedy small model's loop: stop at the first line seen more than max_same times."""
    seen: dict[str, int] = {}
    out = []
    for line in text.splitlines():
        key = re.sub(r"\s+", " ", line.strip())
        if key and not set(key) <= set("|-: "):
            seen[key] = seen.get(key, 0) + 1
            if seen[key] > max_same:
                out.append("[… repeated output cut]")
                break
        out.append(line)
    return "\n".join(out).strip()

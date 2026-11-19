"""The system prompt and the user message built from the sources.

The prompt text lives in system_prompt.txt. Each rule there came from a brief that misled the coding agent:
change it only against the benchmark (bench/run_bench.py), never from one run.
"""
from __future__ import annotations

import base64
import io
from dataclasses import dataclass
from importlib import resources

from PIL import Image

from .config import Config
from typing import Callable

from .extract import Picture, Source


def default_system_prompt() -> str:
    return resources.files("reqbuddy").joinpath("system_prompt.txt").read_text(encoding="utf-8").strip()


def case_report_rule() -> str:
    return resources.files("reqbuddy").joinpath("case_report_rule.txt").read_text(encoding="utf-8").strip()


@dataclass
class Built:
    messages: list[dict]
    preview: str          # the user message as text, images shown as <image WxH>
    image_count: int
    dropped_images: int


def build(sources: list[Source], cfg: Config, notes: str = "", send_images: bool = True,
          image_side: int | None = None, system_prompt: str | None = None,
          transcribe: Callable[[Picture, str], str] | None = None) -> Built:
    """transcribe: for a text-only model, turns each picture into text (see describe.py) that takes its place."""
    parts: list[dict] = []
    preview: list[str] = []

    def add(s: str) -> None:
        parts.append({"type": "text", "text": s})
        preview.append(s)

    head = "## People\n"
    for p in cfg.people:
        if p.name:
            head += f"- {p.name}" + (f" (also: {p.aliases})" if p.aliases else "")
            head += f" - {p.role}" + (" [this is me]" if p.me else "") + "\n"
    if notes.strip():
        head += f"\n## My notes (authoritative, override the sources)\n{notes.strip()}\n"
    head += "\n## Sources\n"
    head += ("Images are attached inline after the text of the source they belong to.\n" if send_images
             else "Images were transcribed to text by a vision model; each transcript follows the source it "
                  "belongs to. [MARKED: …] is what a highlight, box or arrow points at.\n" if transcribe
             else "Images are not available to you; only the text below.\n")
    add(head)

    budget, sent, dropped = max(0, cfg.max_images), 0, 0
    side = image_side or cfg.image_side
    for i, d in enumerate(sources, 1):
        s = f"S{i}"
        # Conversations describe the request; their file names carry people's names and they are never test
        # inputs, so they get neither a name nor a path. Other files might be test inputs.
        if d.kind == "case report":
            t = f"\n### {s}: case run (actual output of our system; never list it as a file)\n"
        elif d.is_conversation:
            t = f"\n### {s}: {d.kind} (describes the request; never list it as a file)\n"
        else:
            t = f"\n### {s}: {d.kind} - {d.path.name}\nPath: {d.path}\n"
        add(t + "\n" + d.text + "\n")
        if not send_images and not transcribe:
            dropped += len(d.pictures)
            continue
        for pic in d.pictures:
            if budget <= 0:
                dropped += 1
                continue
            url, (w, h) = jpeg_data_url(pic.data, side)
            budget -= 1
            sent += 1
            if not send_images:
                add(f"\n[{s} {pic.label}, transcribed]\n{transcribe(pic, f'{s} {pic.label}')}\n")
                continue
            add(f"\n[{s} {pic.label}]\n")
            parts.append({"type": "image_url", "image_url": {"url": url}})
            preview.append(f"<image {w}x{h}>\n")
    if (send_images or transcribe) and dropped:
        add(f"\n({dropped} more images omitted by the image limit.)\n")
    add("\nAll sources above belong to ONE requirement. Write exactly one brief now.")

    system = (system_prompt if system_prompt is not None else cfg.system_prompt).strip() or default_system_prompt()
    if any(d.kind == "case report" for d in sources):
        system += "\n\n" + case_report_rule()
    return Built([{"role": "system", "content": system}, {"role": "user", "content": _merge(parts)}],
                 "".join(preview), sent, dropped)


def _merge(parts: list[dict]) -> list[dict] | str:
    out: list[dict] = []
    for p in parts:
        if p["type"] == "text" and out and out[-1]["type"] == "text":
            out[-1] = {"type": "text", "text": out[-1]["text"] + p["text"]}
        else:
            out.append(p)
    # A plain string for text-only messages: some servers reject the array form without vision.
    return out[0]["text"] if len(out) == 1 and out[0]["type"] == "text" else out


def jpeg_data_url(data: bytes, long_side: int = 1600) -> tuple[str, tuple[int, int]]:
    with Image.open(io.BytesIO(data)) as im:
        im = im.convert("RGB")
        scale = min(1.0, long_side / max(im.size))
        if scale < 1:
            im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=85)
        return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode(), im.size

"""Read the inputs a requirement arrives in: Mail .rtfd, .eml, Lark chat PDFs, other PDFs, screenshots, text."""
from __future__ import annotations

import email
import email.policy
import io
import re
from dataclasses import dataclass, field
from pathlib import Path

import pymupdf
from PIL import Image

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".heic", ".tif", ".tiff", ".bmp", ".webp"}
TEXT_EXTS = {".txt", ".md", ".markdown", ".log", ".csv", ".json"}
EMAIL_EXTS = {".eml"}
RTF_EXTS = {".rtf"}
MIN_IMAGE_SIDE = 48            # smaller pictures are separators and icons
PAGE_RENDER_LONG_SIDE = 2400   # px; what is sent is downscaled later (prompt.image_side)
MAX_PDF_PAGES = 30
CHAT_MARKERS = ("To view more chat history", "查看更多聊天记录")  # Lark / Feishu export header


@dataclass
class Picture:
    label: str               # "Image 3" or "Page 2"
    data: bytes              # encoded image (PNG/JPEG/...)
    path: str | None = None  # file on disk, when the picture is a file of its own

    @property
    def size(self) -> tuple[int, int]:
        with Image.open(io.BytesIO(self.data)) as im:
            return im.size


@dataclass
class Source:
    path: Path
    kind: str                # email, chat, pdf, image, text, case report
    text: str
    pictures: list[Picture] = field(default_factory=list)

    @property
    def is_conversation(self) -> bool:
        """Emails and chats describe the request; they are never files to test with."""
        return self.kind in ("email", "chat")


class ExtractError(Exception):
    pass


def is_supported(p: Path) -> bool:
    e = p.suffix.lower()
    return (e == ".rtfd" or e == ".pdf" or e in IMAGE_EXTS or e in TEXT_EXTS or e in EMAIL_EXTS
            or e in RTF_EXTS)


def expand(paths: list[str | Path]) -> list[Path]:
    """Folders (but not .rtfd packages) become the readable files inside them, sorted by name."""
    out: list[Path] = []
    for raw in paths:
        p = Path(raw).expanduser()
        if p.is_dir() and p.suffix.lower() != ".rtfd":
            out += expand(sorted(c for c in p.iterdir() if not c.name.startswith(".")))
        elif p.exists() and is_supported(p):
            out.append(p)
    return out


def extract(p: Path) -> Source:
    e = p.suffix.lower()
    if e == ".rtfd":
        return read_rtfd(p)
    if e == ".pdf":
        return read_pdf(p)
    if e in IMAGE_EXTS:
        data = p.read_bytes()
        _check_image(data, p)
        return Source(p, "image", "", [Picture("Image 1", data, str(p))])
    if e in EMAIL_EXTS:
        return read_eml(p)
    if e in RTF_EXTS:
        return Source(p, "text", clean(rtf_to_text(p.read_bytes())[0]))
    if e in TEXT_EXTS:
        return Source(p, "text", clean(p.read_text(encoding="utf-8", errors="replace")))
    raise ExtractError(f"unsupported file: {p.name}")


def _check_image(data: bytes, p: Path) -> None:
    try:
        with Image.open(io.BytesIO(data)) as im:
            im.verify()
    except Exception as e:  # noqa: BLE001 - any decoder error means unreadable
        raise ExtractError(f"cannot read image {p.name}: {e}") from e


# ---------------------------------------------------------------- Mail .rtfd

# Mail ("Save As… Rich Text Format with attachments") writes each attachment where it sits in the text as
#   {{\NeXTGraphic <file name> \width… \height… …}<U+FFFC>}
_GRAPHIC = re.compile(rb"\{\{\\NeXTGraphic (?P<name>[^\n]+?) \\width[^}]*\}[^{}]{0,4}\}")


def read_rtfd(p: Path) -> Source:
    rtf = p / "TXT.rtf"
    if not rtf.exists():
        raise ExtractError(f"{p.name} has no TXT.rtf")
    text, names = rtf_to_text(rtf.read_bytes(), graphics=True)
    pictures: list[Picture] = []
    seen: dict[bytes, int] = {}
    def picture(m: re.Match) -> str:
        f = p / names[int(m.group(1))]
        if not f.exists():
            return ""
        data = f.read_bytes()
        if data in seen:  # quoted replies repeat the same attachments
            return f"\n[same as Image {seen[data]}]\n"
        try:
            with Image.open(io.BytesIO(data)) as im:
                if min(im.size) < MIN_IMAGE_SIDE:
                    return ""
        except Exception:  # noqa: BLE001 - not an image: a PDF or other attachment
            return f"\n[attachment: {f.name}]\n"
        pictures.append(Picture(f"Image {len(pictures) + 1}", data, str(f)))
        seen[data] = len(pictures)
        return f"\n[Image {len(pictures)}]\n"
    text = re.sub(r"\x00G(\d+)\x00", picture, text)
    return Source(p, "email", clean(text), pictures)


_DESTINATIONS = {"fonttbl", "colortbl", "expandedcolortbl", "stylesheet", "info", "pict", "listtable",
                 "listoverridetable", "header", "footer", "*"}
_TOKEN = re.compile(rb"\\([a-zA-Z]+)(-?\d+)? ?|\\'([0-9a-fA-F]{2})|\\(.)|([{}])|([^\\{}\r\n]+)|[\r\n]+", re.S)


def rtf_to_text(raw: bytes, graphics: bool = False) -> tuple[str, list[str]]:
    """Plain text from RTF: \\uN and \\'hh decoded, groups like the font table skipped.
    With graphics=True, each \\NeXTGraphic group becomes a \\x00G<i>\\x00 marker; returns the file names."""
    names: list[str] = []
    if graphics:
        def mark(m: re.Match) -> bytes:
            name = m.group("name")
            try:
                names.append(name.decode("utf-8").strip())
            except UnicodeDecodeError:
                names.append(name.decode("latin-1").strip())
            return b"\\'00G" + str(len(names) - 1).encode() + b"\\'00"
        raw = _GRAPHIC.sub(mark, raw)
    m = re.search(rb"\\ansicpg(\d+)", raw)
    codepage = f"cp{m.group(1).decode()}" if m else "cp1252"
    out: list[str] = []
    pending = bytearray()          # \'hh bytes, decoded together (multi-byte code pages)
    stack: list[tuple[bool, int]] = []
    skip, uc, skip_next = False, 1, 0

    def flush() -> None:
        if pending:
            out.append(pending.decode(codepage, errors="replace") if b"\x00" not in pending
                       else pending.decode("latin-1"))
            pending.clear()

    first_in_group = False
    for t in _TOKEN.finditer(raw):
        word, num, hexbyte, sym, brace, plain = t.groups()
        if brace == b"{":
            flush(); stack.append((skip, uc)); first_in_group = True; continue
        if brace == b"}":
            flush()
            if stack:
                skip, uc = stack.pop()
            first_in_group = False
            continue
        if word is not None:
            w = word.decode()
            if first_in_group and w in _DESTINATIONS:
                skip = True
            first_in_group = False
            if skip:
                continue
            if w == "uc":
                uc = int(num or 1)
            elif w == "u":
                flush()
                n = int(num)
                out.append(chr(n + 65536 if n < 0 else n))
                skip_next = uc
            elif w in ("par", "line"):
                flush(); out.append("\n")
            elif w == "tab":
                flush(); out.append("\t")
            continue
        first_in_group = False
        if skip:
            continue
        if hexbyte is not None:
            if skip_next:
                skip_next -= 1; continue
            pending.append(int(hexbyte, 16)); continue
        if sym is not None:
            flush()
            s = sym.decode("latin-1")
            if s == "*":
                skip = True
            elif s in "\n\r":
                out.append("\n")
            elif s in "\\{}":
                out.append(s)
            elif s == "~":
                out.append(" ")
            continue
        if plain is not None:
            flush()
            txt = plain.decode(codepage, errors="replace")
            if skip_next:
                drop = min(skip_next, len(txt)); txt = txt[drop:]; skip_next -= drop
            out.append(txt)
    flush()
    return "".join(out), names


# ---------------------------------------------------------------- PDF (incl. Lark chat exports)

def read_pdf(p: Path) -> Source:
    try:
        doc = pymupdf.open(p)
    except Exception as e:  # noqa: BLE001
        raise ExtractError(f"cannot open {p.name}: {e}") from e
    parts: list[str] = []
    pictures: list[Picture] = []
    for i, page in enumerate(doc):
        if i >= MAX_PDF_PAGES:
            parts.append(f"\n[... {doc.page_count - MAX_PDF_PAGES} more pages omitted]\n")
            break
        parts.append(f"\n--- Page {i + 1} ---\n{page_text(page)}\n")
        pictures.append(Picture(f"Page {i + 1}", render(page)))
    text = clean("".join(parts))
    kind = "chat" if any(m in text for m in CHAT_MARKERS) else "pdf"
    return Source(p, kind, text, pictures)


def page_text(page: pymupdf.Page) -> str:
    """Text in reading order, with [picture] where an image sits (chat exports carry screenshots)."""
    lines: list[str] = []
    for b in page.get_text("dict", sort=True)["blocks"]:
        if b["type"] == 1:
            w, h = b["bbox"][2] - b["bbox"][0], b["bbox"][3] - b["bbox"][1]
            if min(w, h) >= 24:
                lines.append("[picture]")
            continue
        for ln in b["lines"]:
            lines.append("".join(s["text"] for s in ln["spans"]))
    return "\n".join(lines)


def render(page: pymupdf.Page, long_side: int = PAGE_RENDER_LONG_SIDE) -> bytes:
    r = page.rect
    zoom = min(3.0, long_side / max(r.width, r.height))
    return page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False).tobytes("png")


# ---------------------------------------------------------------- .eml

def read_eml(p: Path) -> Source:
    msg = email.message_from_bytes(p.read_bytes(), policy=email.policy.default)
    head = "\n".join(f"{k}: {msg[k]}" for k in ("From", "To", "Cc", "Date", "Subject") if msg[k])
    body = msg.get_body(preferencelist=("plain", "html"))
    text = body.get_content() if body else ""
    if body is not None and body.get_content_type() == "text/html":
        text = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", text, flags=re.S | re.I)
        text = re.sub(r"<br\s*/?>|</p>|</div>|</tr>", "\n", text, flags=re.I)
        text = re.sub(r"<[^>]+>", "", text)
    pictures: list[Picture] = []
    seen: set[bytes] = set()
    for part in msg.walk():
        if part.get_content_maintype() == "image":
            data = part.get_payload(decode=True) or b""
            try:
                with Image.open(io.BytesIO(data)) as im:
                    if min(im.size) < MIN_IMAGE_SIDE or data in seen:
                        continue
            except Exception:  # noqa: BLE001
                continue
            seen.add(data)
            pictures.append(Picture(f"Image {len(pictures) + 1}", data))
    return Source(p, "email", clean(head + "\n\n" + text), pictures)


# ---------------------------------------------------------------- helpers

def clean(s: str) -> str:
    """Collapse export noise: NBSP/zero-width chars, runs of blank lines, long ===== bars."""
    s = s.replace("\u00a0", " ").replace("\u200b", "").replace("\ufffc", "").replace("\u2028", "\n")
    lines, blank = [], 0
    for raw in s.splitlines():
        line = raw.strip()
        if len(line) > 20 and len(set(line)) == 1:
            line = line[:20]
        if not line:
            blank += 1
            if blank > 1:
                continue
        else:
            blank = 0
        lines.append(line)
    return "\n".join(lines).strip()

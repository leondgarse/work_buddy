"""Email over IMAP (read-only). One item per message; replies share a thread key with their root."""

from __future__ import annotations

import html
import imaplib
import json
import re
from email import message_from_bytes, policy
from email.utils import getaddresses, parsedate_to_datetime

from ..model import Item, now_iso
from . import NotConfigured, days_ago

MAX_BODY = 20000


def _html_to_text(s: str) -> str:
    s = re.sub(r"(?is)<(script|style).*?</\1>", "", s)
    s = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</li>|</tr>", "\n", s)
    return html.unescape(re.sub(r"<[^>]+>", "", s))


def _strip_quotes(text: str) -> str:
    """Drop quoted reply text so a thread doesn't repeat itself in every message."""
    lines = []
    for line in text.splitlines():
        if line.lstrip().startswith(">"):
            continue
        if re.match(r"^(On .+ wrote:|-{2,}\s*Original Message\s*-{2,}|在.+写道：?)$", line.strip()):
            break
        lines.append(line)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def _msgid(value) -> str:
    return str(value or "").strip().strip("<>")


def parse_message(raw: bytes, fallback_id: str) -> Item:
    msg = message_from_bytes(raw, policy=policy.default)
    mid = _msgid(msg["Message-ID"]) or fallback_id
    refs = str(msg["References"] or "").split()
    root = _msgid(refs[0]) if refs else _msgid(msg["In-Reply-To"]) or mid

    part = msg.get_body(preferencelist=("plain", "html"))
    body = ""
    if part is not None:
        body = part.get_content()
        if part.get_content_type() == "text/html":
            body = _html_to_text(body)
    body = _strip_quotes(body)[:MAX_BODY]

    try:
        ts = parsedate_to_datetime(str(msg["Date"])).isoformat(timespec="seconds")
    except (TypeError, ValueError):
        ts = now_iso()
    sender = getaddresses([str(msg["From"] or "")])
    others = getaddresses([str(msg[h] or "") for h in ("To", "Cc")])
    attachments = [p.get_filename() for p in msg.iter_attachments() if p.get_filename()]
    if attachments:
        body += "\n\nAttachments: " + ", ".join(attachments)
    return Item(
        id=f"email:{mid}",
        source="email",
        title=str(msg["Subject"] or "(no subject)"),
        body=body,
        ts=ts,
        author=f"{sender[0][0]} <{sender[0][1]}>".strip() if sender else "",
        participants=sorted({a.lower() for _, a in sender + others if a}),
        thread=f"email:{root}",
        refs={"message_id": mid},
    )


def fetch(cfg: dict, store, reqs):
    ecfg = cfg.get("email") or {}
    if not ecfg.get("host") or not ecfg.get("user"):
        raise NotConfigured
    conn = imaplib.IMAP4_SSL(ecfg["host"], int(ecfg.get("port", 993)))
    try:
        conn.login(ecfg["user"], ecfg.get("password", ""))
        for folder in ecfg.get("folders") or ["INBOX"]:
            yield from _fetch_folder(conn, store, ecfg, folder)
    finally:
        try:
            conn.logout()
        except Exception:
            pass


def _fetch_folder(conn, store, ecfg, folder):
    typ, _ = conn.select(f'"{folder}"', readonly=True)
    if typ != "OK":
        raise RuntimeError(f"cannot open folder {folder}")
    validity = (conn.response("UIDVALIDITY")[1] or [b""])[0]
    validity = validity.decode() if isinstance(validity, bytes) else str(validity)
    key = f"email:{ecfg['user']}:{folder}"
    cursor = json.loads(store.get_cursor(key) or "{}")
    if cursor.get("uidvalidity") == validity:
        criteria = f"UID {int(cursor['uid']) + 1}:*"
    else:
        criteria = "SINCE " + days_ago(int(ecfg.get("since_days", 14))).strftime("%d-%b-%Y")
    typ, data = conn.uid("search", None, criteria)
    uids = sorted(int(u) for u in (data[0] or b"").split())
    last = int(cursor.get("uid", 0)) if cursor.get("uidvalidity") == validity else 0
    for uid in uids:
        if uid <= last:  # "UID n:*" always returns the newest message, even when n is past it
            continue
        typ, parts = conn.uid("fetch", str(uid), "(BODY.PEEK[])")
        raw = next((p[1] for p in parts if isinstance(p, tuple)), None)
        if raw:
            yield parse_message(raw, fallback_id=f"{folder}:{validity}:{uid}")
        last = uid
    store.set_cursor(key, json.dumps({"uidvalidity": validity, "uid": last}))

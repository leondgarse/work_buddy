"""Lark / Feishu chats and docs through the Open API, using a self-built app's tenant token.

The app needs the bot added to each chat in `lark.chats`, and read access to each doc. Scopes:
im:message:readonly (or im:message.group_msg), im:chat:readonly, docx:document:readonly,
wiki:wiki:readonly, and optionally contact:user.base:readonly to show sender names.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from ..linker import doc_token, doc_tokens_in
from ..model import Item, now_iso
from . import NotConfigured, days_ago

CHUNK_GAP_SEC = 30 * 60  # messages closer than this form one conversation item
BASES = {"feishu": "https://open.feishu.cn", "lark": "https://open.larksuite.com"}


class LarkError(RuntimeError):
    pass


class LarkClient:
    def __init__(self, app_id: str, app_secret: str, domain: str = "feishu"):
        self.base = BASES.get(domain or "feishu", domain)
        self.app_id, self.app_secret = app_id, app_secret
        self._token, self._expires = "", 0.0

    def _request(self, method: str, path: str, params=None, body=None, auth=True) -> dict:
        url = self.base + path + ("?" + urllib.parse.urlencode(params) if params else "")
        headers = {"Content-Type": "application/json; charset=utf-8"}
        if auth:
            headers["Authorization"] = f"Bearer {self.token()}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            try:
                payload = json.loads(e.read())
            except ValueError:
                raise LarkError(f"{method} {path}: HTTP {e.code}") from e
        if payload.get("code") != 0:
            raise LarkError(f"{method} {path}: code={payload.get('code')} {payload.get('msg')}")
        return payload

    def token(self) -> str:
        if not self._token or time.time() > self._expires - 60:
            payload = self._request("POST", "/open-apis/auth/v3/tenant_access_token/internal",
                                    body={"app_id": self.app_id, "app_secret": self.app_secret}, auth=False)
            self._token = payload["tenant_access_token"]
            self._expires = time.time() + int(payload.get("expire", 3600))
        return self._token

    def call(self, method: str, path: str, params=None, body=None) -> dict:
        return self._request(method, path, params, body).get("data") or {}


def client_from(cfg: dict) -> LarkClient:
    lcfg = cfg.get("lark") or {}
    if not lcfg.get("app_id") or not lcfg.get("app_secret"):
        raise NotConfigured
    return LarkClient(lcfg["app_id"], lcfg["app_secret"], lcfg.get("domain", "feishu"))


# messages ------------------------------------------------------------------


def message_text(msg: dict) -> str:
    """Readable text for one im/v1 message."""
    mtype = msg.get("msg_type")
    try:
        content = json.loads((msg.get("body") or {}).get("content") or "{}")
    except ValueError:
        content = {}
    if mtype == "text":
        text = content.get("text", "")
    elif mtype == "post":
        post = content if "content" in content else next(iter(content.values()), {}) if content else {}
        parts = [post.get("title", "")] if post.get("title") else []
        for para in post.get("content") or []:
            line = ""
            for el in para:
                tag = el.get("tag")
                if tag in ("text", "md"):
                    line += el.get("text", "")
                elif tag == "a":
                    line += f"{el.get('text', '')} ({el.get('href', '')})"
                elif tag == "at":
                    line += "@" + (el.get("user_name") or el.get("user_id", ""))
                elif tag == "code_block":
                    line += el.get("text", "")
            parts.append(line)
        text = "\n".join(parts)
    elif mtype == "file":
        text = f"[file: {content.get('file_name', '')}]"
    elif mtype in ("image", "sticker", "audio", "media"):
        text = f"[{mtype}]"
    elif mtype == "merge_forward":
        text = "[merged forward]"
    elif mtype == "interactive":
        text = "[card] " + (content.get("title") or "")
    else:
        text = f"[{mtype}]"
    for mention in msg.get("mentions") or []:
        text = text.replace(mention.get("key", "\0"), "@" + mention.get("name", ""))
    return text.strip()


def chunk_messages(msgs: list[dict], gap_sec: int = CHUNK_GAP_SEC) -> list[list[dict]]:
    """Split time-ordered messages into conversations separated by quiet gaps."""
    chunks: list[list[dict]] = []
    last = None
    for m in msgs:
        t = int(m["create_time"]) // 1000
        if last is None or t - last > gap_sec:
            chunks.append([])
        chunks[-1].append(m)
        last = t
    return chunks


def chunk_item(chat_id: str, chat_name: str, msgs: list[dict], name_of) -> Item:
    lines, people, docs = [], [], []
    for m in msgs:
        t = datetime.fromtimestamp(int(m["create_time"]) / 1000, timezone.utc)
        sender = name_of((m.get("sender") or {}).get("id", ""))
        text = message_text(m)
        lines.append(f"[{t:%Y-%m-%d %H:%M}] {sender}: {text}")
        people.append(sender)
        docs += doc_tokens_in(text)
    first = message_text(msgs[0]).replace("\n", " ")[:60]
    start = datetime.fromtimestamp(int(msgs[0]["create_time"]) / 1000, timezone.utc)
    return Item(
        id=f"lark_msg:{chat_id}:{msgs[0]['message_id']}",
        source="lark_msg",
        title=f"{chat_name}: {first}",
        body="\n".join(lines),
        ts=start.isoformat(timespec="seconds"),
        author=people[0],
        participants=sorted(set(people)),
        refs={"chat": chat_id, "docs": list(dict.fromkeys(docs)), "messages": len(msgs)},
    )


class _Names:
    """open_id -> display name, cached in the cursor table. Falls back to the id if contact access is missing."""

    def __init__(self, client: LarkClient, store):
        self.client, self.store, self.denied = client, store, False

    def __call__(self, open_id: str) -> str:
        if not open_id:
            return "unknown"
        key = f"lark:user:{open_id}"
        cached = self.store.get_cursor(key)
        if cached:
            return cached
        name = ""
        if not self.denied:
            try:
                user = self.client.call("GET", f"/open-apis/contact/v3/users/{open_id}",
                                        {"user_id_type": "open_id"}).get("user") or {}
                name = user.get("name") or user.get("en_name") or ""
            except LarkError:
                self.denied = True
        if not name:
            return open_id[-8:]
        self.store.set_cursor(key, name)
        return name


def fetch_messages(cfg: dict, store, reqs):
    client = client_from(cfg)
    lcfg = cfg.get("lark") or {}
    chats = list(dict.fromkeys([*(lcfg.get("chats") or []), *(c for r in reqs for c in r.list("lark_chats"))]))
    if not chats:
        raise NotConfigured
    names = _Names(client, store)
    for chat_id in chats:
        key = f"lark_msg:{chat_id}"
        start = int(store.get_cursor(key) or days_ago(int(lcfg.get("since_days", 14))).timestamp())
        try:
            chat_name = client.call("GET", f"/open-apis/im/v1/chats/{chat_id}").get("name") or chat_id
        except LarkError:
            chat_name = chat_id
        msgs, page = [], None
        while True:
            params = {"container_id_type": "chat", "container_id": chat_id, "start_time": str(start),
                      "sort_type": "ByCreateTimeAsc", "page_size": "50"}
            if page:
                params["page_token"] = page
            data = client.call("GET", "/open-apis/im/v1/messages", params)
            msgs += [m for m in data.get("items") or [] if not m.get("deleted")]
            if not data.get("has_more"):
                break
            page = data.get("page_token")
        chunks = chunk_messages(msgs)
        for chunk in chunks:
            yield chunk_item(chat_id, chat_name, chunk, names)
        if chunks:
            # Resume from the start of the last conversation so it keeps growing as one item.
            store.set_cursor(key, str(int(chunks[-1][0]["create_time"]) // 1000))


# docs ----------------------------------------------------------------------


def _resolve_doc(client: LarkClient, ref: str) -> tuple[str, list[str], str]:
    """Return (docx document_id, tokens that identify it, title) for a doc/wiki URL or token."""
    token = doc_token(ref)
    if "/wiki/" in ref:
        node = client.call("GET", "/open-apis/wiki/v2/spaces/get_node", {"token": token}).get("node") or {}
        if node.get("obj_type") != "docx":
            raise LarkError(f"{ref}: wiki node is a {node.get('obj_type')}, only docx is supported")
        return node["obj_token"], [node["obj_token"], token], node.get("title", "")
    try:
        client.call("GET", f"/open-apis/docx/v1/documents/{token}")
        return token, [token], ""
    except LarkError:
        node = client.call("GET", "/open-apis/wiki/v2/spaces/get_node", {"token": token}).get("node") or {}
        if node.get("obj_type") != "docx":
            raise
        return node["obj_token"], [node["obj_token"], token], node.get("title", "")


def fetch_docs(cfg: dict, store, reqs):
    client = client_from(cfg)
    refs = list(dict.fromkeys([*((cfg.get("lark") or {}).get("docs") or []),
                               *(d for r in reqs for d in r.list("lark_docs"))]))
    if not refs:
        raise NotConfigured
    errors = []
    for ref in refs:
        try:
            doc_id, tokens, wiki_title = _resolve_doc(client, ref)
            doc = client.call("GET", f"/open-apis/docx/v1/documents/{doc_id}").get("document") or {}
            revision = str(doc.get("revision_id", ""))
            existing = store.get(f"lark_doc:{doc_id}")
            if existing and existing["revision"] == revision:
                continue
            content = client.call("GET", f"/open-apis/docx/v1/documents/{doc_id}/raw_content").get("content", "")
        except LarkError as e:
            errors.append(str(e))
            continue
        yield Item(
            id=f"lark_doc:{doc_id}",
            source="lark_doc",
            title=doc.get("title") or wiki_title or doc_id,
            body=content,
            ts=now_iso(),
            url=ref if ref.startswith("http") else "",
            revision=revision,
            refs={"docs": tokens},
        )
    if errors:
        raise LarkError("; ".join(errors))

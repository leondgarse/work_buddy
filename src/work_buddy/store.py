"""SQLite state (items, links, inbox, sync cursors, full-text index) plus the item files on disk."""

from __future__ import annotations

import json
import os
import re
import sqlite3
from contextlib import contextmanager
from pathlib import Path

from .dossier import req_dir
from .model import Item, now_iso

SCHEMA = """
create table if not exists items(
  id text primary key, source text, title text, author text, ts text, url text,
  path text, hash text, revision text, thread text, refs text, participants text, fetched_at text);
create index if not exists items_thread on items(thread);
create table if not exists links(
  item_id text, req_id text, method text, score real,
  summarized integer default 0, created_at text, primary key(item_id, req_id));
create table if not exists inbox(item_id text primary key, suggestions text, status text default 'open');
create table if not exists cursors(key text primary key, value text);
create virtual table if not exists fts using fts5(item_id unindexed, title, body, tokenize='trigram');
"""


class Store:
    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(root / "index.sqlite")
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self._batching = False

    def close(self) -> None:
        self.db.close()

    def _commit(self) -> None:
        if not self._batching:
            self.db.commit()

    @contextmanager
    def batch(self):
        """Group writes into one transaction (per-row commits fsync, which is slow on macOS).
        Commits even when the body fails: stored items match the files already written, and
        sources only advance their cursor at the end, so the next sync re-fetches the rest."""
        self._batching = True
        try:
            yield
        finally:
            self._batching = False
            self.db.commit()

    # cursors -------------------------------------------------------------

    def get_cursor(self, key: str) -> str | None:
        row = self.db.execute("select value from cursors where key=?", (key,)).fetchone()
        return row["value"] if row else None

    def set_cursor(self, key: str, value: str) -> None:
        self.db.execute("insert or replace into cursors(key, value) values(?, ?)", (key, value))
        self._commit()

    # items ---------------------------------------------------------------

    def upsert(self, item: Item) -> str:
        """Store item; returns 'new', 'updated' or 'unchanged'. Updates re-open its links for summarizing."""
        digest = item.content_hash()
        row = self.db.execute("select path, hash, fetched_at from items where id=?", (item.id,)).fetchone()
        if row and row["hash"] == digest:
            return "unchanged"
        if row:
            rel = row["path"]
            old = self.root / rel
            if old.exists():
                hist = self.root / "items" / "_history" / Path(rel).stem
                hist.mkdir(parents=True, exist_ok=True)
                old.replace(hist / f"{re.sub(r'[^0-9T]', '', row['fetched_at'])}.md")
        else:
            rel = f"items/{item.source}/{item.file_stem()}.md"
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(item.to_markdown())

        values = (
            item.source, item.title, item.author, item.ts, item.url, rel, digest, item.revision,
            item.thread, json.dumps(item.refs, ensure_ascii=False),
            json.dumps(item.participants, ensure_ascii=False), now_iso(),
        )
        if row:
            self.db.execute(
                "update items set source=?, title=?, author=?, ts=?, url=?, path=?, hash=?, revision=?,"
                " thread=?, refs=?, participants=?, fetched_at=? where id=?", (*values, item.id))
            self.db.execute("delete from fts where item_id=?", (item.id,))
            self.db.execute("update links set summarized=0 where item_id=?", (item.id,))
        else:
            self.db.execute("insert into items(source, title, author, ts, url, path, hash, revision,"
                            " thread, refs, participants, fetched_at, id) values(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                            (*values, item.id))
        self.db.execute("insert into fts(item_id, title, body) values(?, ?, ?)", (item.id, item.title, item.body))
        self._commit()
        return "updated" if row else "new"

    def get(self, item_id: str) -> sqlite3.Row | None:
        return self.db.execute("select * from items where id=?", (item_id,)).fetchone()

    def load_item(self, item_id: str) -> Item | None:
        row = self.db.execute(
            "select i.*, f.body from items i join fts f on f.item_id = i.id where i.id=?", (item_id,)).fetchone()
        return _row_to_item(row) if row else None

    def iter_items(self):
        rows = self.db.execute("select i.*, f.body from items i join fts f on f.item_id = i.id order by i.ts")
        for row in rows.fetchall():
            yield _row_to_item(row)

    # links ---------------------------------------------------------------

    def link(self, item_id: str, req_id: str, method: str, score: float = 1.0) -> bool:
        """Link an item to a requirement; returns False if it already was."""
        cur = self.db.execute(
            "insert or ignore into links(item_id, req_id, method, score, created_at) values(?,?,?,?,?)",
            (item_id, req_id, method, score, now_iso()))
        self.db.execute("delete from inbox where item_id=?", (item_id,))
        self._commit()
        self._symlink(item_id, req_id)
        return cur.rowcount > 0

    def unlink(self, item_id: str, req_id: str) -> None:
        self.db.execute("delete from links where item_id=? and req_id=?", (item_id, req_id))
        self._commit()
        row = self.get(item_id)
        if row:
            (req_dir(self.root, req_id) / "sources" / Path(row["path"]).name).unlink(missing_ok=True)

    def _symlink(self, item_id: str, req_id: str) -> None:
        row = self.get(item_id)
        sources = req_dir(self.root, req_id) / "sources"
        if not row or not sources.exists():
            return
        dest = sources / Path(row["path"]).name
        if not dest.is_symlink():
            dest.symlink_to(os.path.relpath(self.root / row["path"], sources))

    def links_for(self, item_id: str) -> list[str]:
        return [r["req_id"] for r in self.db.execute("select req_id from links where item_id=?", (item_id,))]

    def reqs_for_thread(self, thread: str, exclude: str) -> set[str]:
        rows = self.db.execute(
            "select distinct l.req_id from links l join items i on i.id = l.item_id"
            " where i.thread=? and i.id != ?", (thread, exclude))
        return {r["req_id"] for r in rows}

    def pending(self, req_id: str) -> list[sqlite3.Row]:
        return self.db.execute(
            "select i.*, l.method from links l join items i on i.id = l.item_id"
            " where l.req_id=? and l.summarized=0 order by i.ts", (req_id,)).fetchall()

    def mark_done(self, req_id: str, item_ids: list[str] | None = None) -> int:
        if item_ids:
            marks = ",".join("?" * len(item_ids))
            cur = self.db.execute(
                f"update links set summarized=1 where req_id=? and item_id in ({marks})", (req_id, *item_ids))
        else:
            cur = self.db.execute("update links set summarized=1 where req_id=?", (req_id,))
        self._commit()
        return cur.rowcount

    def req_stats(self, req_id: str) -> dict:
        row = self.db.execute(
            "select count(*) n, sum(summarized=0) pending, max(i.ts) latest from links l"
            " join items i on i.id = l.item_id where l.req_id=?", (req_id,)).fetchone()
        return {"items": row["n"], "pending": row["pending"] or 0, "latest": row["latest"] or ""}

    # inbox ---------------------------------------------------------------

    def to_inbox(self, item_id: str, suggestions: list[dict]) -> None:
        self.db.execute(
            "insert into inbox(item_id, suggestions) values(?, ?) on conflict(item_id)"
            " do update set suggestions=excluded.suggestions where status='open'",
            (item_id, json.dumps(suggestions)))
        self._commit()

    def ignore(self, item_id: str) -> None:
        self.db.execute("update inbox set status='ignored' where item_id=?", (item_id,))
        self._commit()

    def inbox(self, limit: int = 50, source: str | None = None) -> list[sqlite3.Row]:
        sql = ("select i.*, b.suggestions from inbox b join items i on i.id = b.item_id where b.status='open'")
        params: list = []
        if source:
            sql += " and i.source=?"
            params.append(source)
        return self.db.execute(sql + " order by i.ts desc limit ?", (*params, limit)).fetchall()

    def in_inbox(self, item_id: str) -> bool:
        return self.db.execute("select 1 from inbox where item_id=? and status='open'", (item_id,)).fetchone() is not None

    def inbox_count(self) -> int:
        return self.db.execute("select count(*) from inbox where status='open'").fetchone()[0]

    # search --------------------------------------------------------------

    def search(self, query: str, req_id: str | None = None, source: str | None = None,
               limit: int = 20) -> list[dict]:
        """Full-text search. Terms are ANDed; quote phrases. Terms under 3 characters (common for
        Chinese words) can't use the trigram index and fall back to substring matching."""
        terms = [a or b for a, b in re.findall(r'"([^"]+)"|(\S+)', query)]
        results = self._search(terms, req_id, source, limit, " AND ")
        if not results and len(terms) > 1:
            results = self._search(terms, req_id, source, limit, " OR ")
        return results

    def _search(self, terms, req_id, source, limit, op) -> list[dict]:
        long_terms = [t for t in terms if len(t) >= 3]
        short_terms = [t for t in terms if len(t) < 3]
        if op == " OR " and long_terms and short_terms:
            # FTS5 cannot put MATCH inside an OR, so run each side separately.
            return self._merge_or(long_terms, short_terms, req_id, source, limit)
        where: list[str] = []
        params: list = []
        if req_id:
            where.append("i.id in (select item_id from links where req_id=?)")
            params.append(req_id)
        if source:
            where.append("i.source=?")
            params.append(source)
        text_conds = []
        if long_terms:
            text_conds.append("fts MATCH ?")
            params.append(op.join('"' + t.replace('"', '""') + '"' for t in long_terms))
        for t in short_terms:
            text_conds.append("(fts.title LIKE ? OR fts.body LIKE ?)")
            params += [f"%{t}%"] * 2
        if text_conds:
            where.append("(" + op.join(text_conds) + ")")
        order = "bm25(fts)" if long_terms else "i.ts desc"
        sql = ("select i.id, i.source, i.ts, i.title, i.path, i.url, fts.body,"
               + (" snippet(fts, 2, '[', ']', '…', 16) snip" if long_terms else " '' snip")
               + " from fts join items i on i.id = fts.item_id"
               + (" where " + " and ".join(where) if where else "")
               + f" order by {order} limit ?")
        rows = self.db.execute(sql, (*params, limit)).fetchall()
        return [_result(r, terms) for r in rows]

    def _merge_or(self, long_terms, short_terms, req_id, source, limit) -> list[dict]:
        seen: dict[str, dict] = {}
        for group in (long_terms, *([t] for t in short_terms)):
            for r in self._search(group, req_id, source, limit, " OR "):
                seen.setdefault(r["id"], r)
        return list(seen.values())[:limit]


def _result(row: sqlite3.Row, terms: list[str]) -> dict:
    snip = row["snip"] or _snippet(row["body"], terms)
    return {"id": row["id"], "source": row["source"], "ts": row["ts"], "title": row["title"],
            "path": row["path"], "url": row["url"], "snippet": " ".join(snip.split())}


def _snippet(body: str, terms: list[str], width: int = 60) -> str:
    low = body.lower()
    for t in terms:
        i = low.find(t.lower())
        if i >= 0:
            start = max(0, i - width)
            return ("…" if start else "") + body[start:i] + f"[{body[i:i + len(t)]}]" + body[i + len(t):i + width] + "…"
    return body[:width * 2]


def _row_to_item(row: sqlite3.Row) -> Item:
    return Item(
        id=row["id"], source=row["source"], title=row["title"], body=row["body"], ts=row["ts"],
        author=row["author"] or "", url=row["url"] or "", participants=json.loads(row["participants"] or "[]"),
        refs=json.loads(row["refs"] or "{}"), revision=row["revision"] or "", thread=row["thread"] or "")

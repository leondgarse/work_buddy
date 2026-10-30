"""Pull every configured source, store new/changed items, and link them."""

from __future__ import annotations

from collections import Counter, defaultdict
from pathlib import Path

from . import dossier, linker
from .sources import NotConfigured, email_src, git_src, lark, meeting
from .store import Store

SOURCES = {
    "lark_msg": lark.fetch_messages,
    "lark_doc": lark.fetch_docs,
    "email": email_src.fetch,
    "git": git_src.fetch,
    "meeting": meeting.fetch,
}


def run(root: Path, store: Store, cfg: dict, only: list[str] | None = None) -> dict:
    reqs = dossier.load_all(root, include_closed=False)
    report: dict = {"sources": {}, "linked": defaultdict(list), "inbox_new": 0}
    for name, fetch in SOURCES.items():
        if only and name not in only:
            continue
        counts: Counter = Counter()
        try:
            with store.batch():
                _pull(fetch(cfg, store, reqs), store, reqs, counts, report)
            report["sources"][name] = dict(counts) or "no changes"
        except NotConfigured:
            report["sources"][name] = "not configured"
        except Exception as e:  # one broken source must not stop the others
            report["sources"][name] = {**counts, "error": f"{type(e).__name__}: {e}"}
    report["inbox_open"] = store.inbox_count()
    return report


def _pull(items, store, reqs, counts, report) -> None:
    for item in items:
        status = store.upsert(item)
        if status == "unchanged":
            continue
        counts[status] += 1
        linked = linker.link_item(store, item, reqs)
        for req_id in linked or store.links_for(item.id):
            report["linked"][req_id].append(f"{status}: {item.title}")
        if not store.links_for(item.id) and store.in_inbox(item.id):
            report["inbox_new"] += 1


def format_report(report: dict) -> str:
    lines = ["Sources:"]
    for name, result in report["sources"].items():
        if isinstance(result, dict):
            result = ", ".join(f"{k}={v}" for k, v in result.items())
        lines.append(f"  {name}: {result}")
    if report["linked"]:
        lines.append("Requirements with new or changed sources (run `wb pending <ID>`):")
        for req_id, titles in sorted(report["linked"].items()):
            lines.append(f"  {req_id}: {len(titles)}")
            lines += [f"    - {t[:100]}" for t in titles[:10]]
            if len(titles) > 10:
                lines.append(f"    … {len(titles) - 10} more")
    else:
        lines.append("No requirement got new sources.")
    lines.append(f"Inbox: {report['inbox_new']} new unlinked, {report['inbox_open']} open (run `wb inbox`)")
    return "\n".join(lines)

"""wb: command-line interface. Data lives in $WB_HOME (default ~/.work_buddy)."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import dossier, linker, sync
from .config import CONFIG_TEMPLATE, home, load_config
from .sources import meeting
from .store import Store


def _out(args, data, text: str) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2, default=str) if args.json else text)


def cmd_init(args, root: Path, store: Store) -> None:
    cfg = root / "config.yaml"
    if not cfg.exists():
        cfg.write_text(CONFIG_TEMPLATE)
    (root / "requirements").mkdir(exist_ok=True)
    print(f"WB_HOME: {root}\nconfig:  {cfg}\nPut secrets in {root / '.env'} (LARK_APP_ID=..., EMAIL_PASSWORD=...)")


def cmd_req_new(args, root, store) -> None:
    req = dossier.create(root, args.id, args.title, args.alias)
    print(f"created {req.dir}\nedit {req.dir / 'meta.yaml'} to add chats, docs, repos, then run `wb req relink {req.id}`")


def cmd_req_list(args, root, store) -> None:
    rows = [{"id": r.id, "title": r.title, "status": r.meta.get("status", "active"), **store.req_stats(r.id)}
            for r in dossier.load_all(root)]
    text = "\n".join(f"{r['id']:<16} {r['status']:<8} items={r['items']:<4} pending={r['pending']:<4}"
                     f" latest={r['latest'][:10]:<10} {r['title']}" for r in rows) or "no requirements yet"
    _out(args, rows, text)


def cmd_req_show(args, root, store) -> None:
    req = dossier.load(root, args.id)
    stats = store.req_stats(req.id)
    print(f"{req.id}: {req.title}\ndir:      {req.dir}\ncontext:  {req.dir / 'context.md'}\n"
          f"timeline: {req.dir / 'timeline.md'}\nitems: {stats['items']}  pending: {stats['pending']}  "
          f"latest: {stats['latest']}\n\nmeta.yaml:\n{(req.dir / 'meta.yaml').read_text()}")


def cmd_req_relink(args, root, store) -> None:
    reqs = dossier.load_all(root, include_closed=False)
    if args.id:
        reqs = [r for r in reqs if r.id == args.id]
    added = 0
    for item in store.iter_items():
        added += len(linker.link_item(store, item, reqs))
    print(f"{added} new links; inbox has {store.inbox_count()} open items")


def cmd_sync(args, root, store) -> None:
    only = args.only.split(",") if args.only else None
    report = sync.run(root, store, load_config(root), only)
    _out(args, report, sync.format_report(report))
    if args.gate:
        errors = any(isinstance(r, dict) and "error" in r for r in report["sources"].values())
        if not (report["linked"] or report["inbox_new"] or errors):
            print(json.dumps({"wakeAgent": False}))


def cmd_add(args, root, store) -> None:
    item = meeting.parse_file(Path(args.file), source=args.source)
    if args.title:
        item.title = args.title
    status = store.upsert(item)
    if args.req:
        dossier.load(root, args.req)
        store.link(item.id, args.req, "manual")
        linked = [args.req]
    else:
        linked = linker.link_item(store, item, dossier.load_all(root, include_closed=False))
    print(f"{status}: {item.id}\nlinked: {', '.join(linked) or '(none, in inbox)'}")


def cmd_inbox(args, root, store) -> None:
    rows = [{"id": r["id"], "source": r["source"], "ts": r["ts"], "title": r["title"], "path": r["path"],
             "suggestions": json.loads(r["suggestions"] or "[]")} for r in store.inbox(args.limit, args.source)]
    lines = []
    for r in rows:
        sug = ", ".join(f"{s['req']}({s['score']}: {'+'.join(s['why'])})" for s in r["suggestions"]) or "-"
        lines.append(f"{r['ts'][:10]} [{r['source']}] {r['title'][:80]}\n    id: {r['id']}\n"
                     f"    file: {root / r['path']}\n    suggest: {sug}")
    _out(args, rows, "\n".join(lines) or "inbox empty")


def cmd_link(args, root, store) -> None:
    if not store.get(args.item):
        sys.exit(f"no item {args.item}")
    dossier.load(root, args.req)
    store.link(args.item, args.req, "manual")
    print(f"linked {args.item} -> {args.req}")


def cmd_unlink(args, root, store) -> None:
    store.unlink(args.item, args.req)
    print(f"unlinked {args.item} from {args.req}")


def cmd_ignore(args, root, store) -> None:
    for item_id in args.items:
        store.ignore(item_id)
    print(f"ignored {len(args.items)} item(s)")


def cmd_pending(args, root, store) -> None:
    dossier.load(root, args.id)
    rows = [{"id": r["id"], "source": r["source"], "ts": r["ts"], "title": r["title"],
             "file": str(root / r["path"]), "linked_by": r["method"]} for r in store.pending(args.id)]
    text = "\n".join(f"{r['ts'][:16]} [{r['source']}] {r['title'][:80]}\n    {r['file']}" for r in rows)
    _out(args, rows, text or f"{args.id}: nothing pending")


def cmd_done(args, root, store) -> None:
    n = store.mark_done(args.id, args.items or None)
    print(f"{args.id}: marked {n} item(s) summarized")


def cmd_search(args, root, store) -> None:
    rows = store.search(" ".join(args.query), args.req, args.source, args.limit)
    for r in rows:
        r["file"] = str(root / r.pop("path"))
        r["reqs"] = store.links_for(r["id"])
    text = "\n".join(f"{r['ts'][:10]} [{r['source']}] {r['title'][:80]}  {','.join(r['reqs']) or '-'}\n"
                     f"    {r['file']}\n    {r['snippet'][:240]}" for r in rows)
    _out(args, rows, text or "no matches")


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    p = argparse.ArgumentParser(prog="wb", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", parents=[common], help="create WB_HOME and config.yaml").set_defaults(fn=cmd_init)

    req = sub.add_parser("req", parents=[common], help="manage requirements").add_subparsers(dest="req_cmd", required=True)
    s = req.add_parser("new", parents=[common], help="create a requirement dossier")
    s.add_argument("id")
    s.add_argument("--title", required=True)
    s.add_argument("--alias", action="append", default=[], help="repeatable")
    s.set_defaults(fn=cmd_req_new)
    req.add_parser("list", parents=[common]).set_defaults(fn=cmd_req_list)
    s = req.add_parser("show", parents=[common])
    s.add_argument("id")
    s.set_defaults(fn=cmd_req_show)
    s = req.add_parser("relink", parents=[common], help="re-run linking over stored items after editing meta.yaml")
    s.add_argument("id", nargs="?")
    s.set_defaults(fn=cmd_req_relink)

    s = sub.add_parser("sync", parents=[common], help="pull all configured sources")
    s.add_argument("--only", help="comma list: lark_msg,lark_doc,email,git,meeting")
    s.add_argument("--gate", action="store_true",
                   help='for Hermes cron: end with {"wakeAgent": false} when there is nothing to do')
    s.set_defaults(fn=cmd_sync)

    s = sub.add_parser("add", parents=[common], help="import a local file (transcript, notes, exported doc)")
    s.add_argument("file")
    s.add_argument("--source", default="meeting")
    s.add_argument("--title")
    s.add_argument("--req", help="link to this requirement instead of auto-linking")
    s.set_defaults(fn=cmd_add)

    s = sub.add_parser("inbox", parents=[common], help="items no requirement claimed")
    s.add_argument("--limit", type=int, default=30)
    s.add_argument("--source")
    s.set_defaults(fn=cmd_inbox)

    for name, fn, hlp in (("link", cmd_link, "link an item"), ("unlink", cmd_unlink, "remove a link")):
        s = sub.add_parser(name, parents=[common], help=hlp)
        s.add_argument("item")
        s.add_argument("req")
        s.set_defaults(fn=fn)

    s = sub.add_parser("ignore", parents=[common], help="drop items from the inbox")
    s.add_argument("items", nargs="+")
    s.set_defaults(fn=cmd_ignore)

    s = sub.add_parser("pending", parents=[common], help="linked items not yet summarized into context.md")
    s.add_argument("id")
    s.set_defaults(fn=cmd_pending)

    s = sub.add_parser("done", parents=[common], help="mark pending items summarized (all, or the given ids)")
    s.add_argument("id")
    s.add_argument("items", nargs="*")
    s.set_defaults(fn=cmd_done)

    s = sub.add_parser("search", parents=[common], help="full-text search over all items")
    s.add_argument("query", nargs="+")
    s.add_argument("--req")
    s.add_argument("--source")
    s.add_argument("--limit", type=int, default=15)
    s.set_defaults(fn=cmd_search)
    return p


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    root = home()
    store = Store(root)
    try:
        args.fn(args, root, store)
    except (KeyError, ValueError) as e:
        sys.exit(f"error: {e.args[0] if e.args else e}")
    finally:
        store.close()


if __name__ == "__main__":
    main()

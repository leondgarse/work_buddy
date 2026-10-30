import json
import subprocess
from pathlib import Path

import pytest

from work_buddy import cli, dossier, linker, sync
from work_buddy.model import Item
from work_buddy.sources import email_src, git_src, lark, meeting
from work_buddy.store import Store


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("WB_HOME", str(tmp_path / "wb"))
    return tmp_path / "wb"


@pytest.fixture
def store(root):
    s = Store(root)
    yield s
    s.close()


def item(id="x:1", title="hello", body="body", **kw):
    return Item(id=id, source=kw.pop("source", "meeting"), title=title, body=body,
                ts=kw.pop("ts", "2026-10-01T00:00:00+00:00"), **kw)


def test_upsert_new_unchanged_updated_keeps_history(root, store):
    req = dossier.create(root, "REQ-1", "Refund")
    it = item(body="v1")
    assert store.upsert(it) == "new"
    store.link(it.id, req.id, "manual")
    store.mark_done(req.id)
    assert store.upsert(it) == "unchanged"
    it.body = "v2"
    assert store.upsert(it) == "updated"
    path = root / store.get(it.id)["path"]
    assert "v2" in path.read_text()
    assert list((root / "items" / "_history").rglob("*.md"))
    assert [r["id"] for r in store.pending(req.id)] == [it.id]  # update re-opens it
    assert (req.dir / "sources" / path.name).resolve() == path.resolve()


def test_linker_rules(root, store):
    req = dossier.create(root, "PAY-7", "Refunds", aliases=["refund flow", "退款"])
    req.meta.update(lark_chats=["oc_1"], lark_docs=["https://x.feishu.cn/wiki/WikTok12345"],
                    repos={str(root): ["src/pay/"]}, people=["alice@x.com"])

    def s(it):
        return linker.score(it, req, set()).score

    assert s(item(body="see pay-7 for details")) == 1.0
    assert s(item(body="PAY-70 is different")) == 0
    assert s(item(title="退款 review")) == 0.7
    assert s(item(body="the refund flow")) == 0.5
    assert s(item(body="refund flow and 退款")) == 0.8
    assert s(item(body="refund flows")) == 0  # English aliases match whole words only
    assert s(item(refs={"chat": "oc_1"})) == 1.0
    assert s(item(refs={"docs": ["WikTok12345"]})) == 0.9
    assert s(item(refs={"repo": str(root.resolve()), "paths": ["src/pay/a.py"]})) == 0.9
    assert s(item(refs={"repo": str(root.resolve()), "paths": ["src/other.py"]})) == 0
    assert s(item(participants=["alice@x.com"])) == 0.2
    assert s(item(body="refund flow", participants=["alice@x.com"])) == pytest.approx(0.6)


def test_thread_inheritance_and_inbox(root, store):
    req = dossier.create(root, "REQ-2", "Search", aliases=["ranking"])
    reqs = [req]
    first = item(id="email:a", source="email", title="REQ-2 kickoff", thread="email:a")
    reply = item(id="email:b", source="email", title="Re: kickoff", thread="email:a")
    other = item(id="email:c", source="email", title="lunch?", body="also ranking", thread="email:c")
    noise = item(id="email:d", source="email", title="newsletter", thread="email:d")
    for it in (first, reply, other, noise):
        store.upsert(it)
        linker.link_item(store, it, reqs)
    assert store.links_for("email:b") == ["REQ-2"]
    # Weak match (body alias) needs triage; no match at all stays out of the inbox but is searchable.
    assert [r["id"] for r in store.inbox()] == ["email:c"]
    assert [r["id"] for r in store.search("newsletter")] == ["email:d"]
    store.ignore("email:c")
    assert store.inbox_count() == 0


def test_search_english_chinese_and_req_filter(root, store):
    req = dossier.create(root, "REQ-3", "x")
    store.upsert(item(id="a", title="Payment design", body="We decided to use idempotency keys. 退款需要审批"))
    store.upsert(item(id="b", title="Other", body="idempotency is unrelated here"))
    store.link("a", req.id, "manual")
    assert {r["id"] for r in store.search("idempotency")} == {"a", "b"}
    assert [r["id"] for r in store.search("退款")] == ["a"]  # 2-char CJK term: substring fallback
    assert [r["id"] for r in store.search("idempotency 审批")] == ["a"]
    assert [r["id"] for r in store.search("idempotency", req_id=req.id)] == ["a"]
    assert [r["id"] for r in store.search('"use idempotency keys"')] == ["a"]
    assert store.search("nomatchword") == []
    assert "[" in store.search("idempotency")[0]["snippet"]


def test_meeting_vtt(tmp_path):
    f = tmp_path / "2026-10-20 sync.vtt"
    f.write_text("WEBVTT\n\n1\n00:00:01.000 --> 00:00:03.000\n<v Alice>We ship Friday</v>\n\n"
                 "2\n00:00:03.000 --> 00:00:05.000\n<v Alice>We ship Friday</v>\n<v Bob>OK</v>\n")
    it = meeting.parse_file(f)
    assert it.body == "Alice: We ship Friday\nBob: OK"
    assert it.ts.startswith("2026-10-20")
    assert it.title == "2026-10-20 sync"
    assert it.file_stem().startswith("2026-10-20_sync_")  # date not repeated


def test_git_source(root, store, tmp_path):
    repo = tmp_path / "proj"
    repo.mkdir()
    run = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
    run("init", "-q")
    run("config", "user.email", "dev@x.com")
    run("config", "user.name", "Dev")
    (repo / "src").mkdir()
    (repo / "src" / "pay.py").write_text("x")
    run("add", ".")
    run("commit", "-qm", "Add refund endpoint\n\nPart of PAY-1")
    run("remote", "add", "origin", "git@github.com:acme/proj.git")
    cfg = {"git": {"repos": [str(repo)]}}
    items = list(git_src.fetch(cfg, store, []))
    assert len(items) == 1
    it = items[0]
    assert it.title == "[proj] Add refund endpoint"
    assert it.refs["paths"] == ["src/pay.py"]
    assert it.url.startswith("https://github.com/acme/proj/commit/")
    assert "PAY-1" in it.body
    assert store.get_cursor(f"git:{repo.resolve()}")


def test_git_web_url():
    assert git_src.web_url("git@github.com:a/b.git") == "https://github.com/a/b"
    assert git_src.web_url("https://gitlab.com/a/b.git") == "https://gitlab.com/a/b"
    assert git_src.web_url("/local/path") == ""


def test_email_parse_threads_and_quotes():
    raw = (b"Message-ID: <m2@x>\r\nIn-Reply-To: <m1@x>\r\nReferences: <m1@x>\r\n"
           b"From: Alice <alice@x.com>\r\nTo: bob@x.com\r\nCc: Carol <carol@x.com>\r\n"
           b"Subject: Re: scope\r\nDate: Tue, 20 Oct 2026 10:00:00 +0800\r\n"
           b"Content-Type: text/plain; charset=utf-8\r\n\r\n"
           b"Agreed, drop export.\r\n\r\nOn Mon, Bob wrote:\r\n> old text\r\n")
    it = email_src.parse_message(raw, "fallback")
    assert it.id == "email:m2@x" and it.thread == "email:m1@x"
    assert it.body == "Agreed, drop export."
    assert it.participants == ["alice@x.com", "bob@x.com", "carol@x.com"]
    assert it.ts == "2026-10-20T10:00:00+08:00"


def _msg(mid, t_sec, mtype, content, sender="ou_1", mentions=None):
    return {"message_id": mid, "create_time": str(t_sec * 1000), "msg_type": mtype,
            "body": {"content": json.dumps(content)}, "sender": {"id": sender}, "mentions": mentions or []}


def test_lark_message_text_and_chunks():
    t0 = 1_800_000_000
    msgs = [
        _msg("m1", t0, "text", {"text": "@_user_1 doc: https://x.feishu.cn/docx/DocTok12345"},
             mentions=[{"key": "@_user_1", "name": "Bob"}]),
        _msg("m2", t0 + 60, "post", {"zh_cn": {"title": "Plan", "content": [[{"tag": "text", "text": "step 1"}]]}}),
        _msg("m3", t0 + 4000, "file", {"file_name": "spec.pdf"}, sender="ou_2"),
    ]
    assert lark.message_text(msgs[0]).startswith("@Bob doc:")
    assert lark.message_text(msgs[1]) == "Plan\nstep 1"
    chunks = lark.chunk_messages(msgs)
    assert [len(c) for c in chunks] == [2, 1]
    it = lark.chunk_item("oc_9", "Team", chunks[0], lambda i: {"ou_1": "Alice"}.get(i, i))
    assert it.id == "lark_msg:oc_9:m1"
    assert it.refs["docs"] == ["DocTok12345"] and it.refs["chat"] == "oc_9"
    assert "Alice: Plan\nstep 1" in it.body


def test_sync_end_to_end_and_cli(root, tmp_path, capsys):
    notes = tmp_path / "notes"
    notes.mkdir()
    (notes / "2026-10-21_pay.md").write_text("# PAY-1 weekly\n\nDecision: launch behind a flag.")
    (notes / "2026-10-22_misc.md").write_text("# Random\n\nmaybe about refunds")
    (notes / "2026-10-23_noise.md").write_text("# Lunch\n\nnothing relevant")
    cli.main(["init"])
    (root / "config.yaml").write_text(f"meetings:\n  dirs: [{notes}]\n")
    cli.main(["req", "new", "PAY-1", "--title", "Refunds", "--alias", "refunds"])
    capsys.readouterr()

    cli.main(["sync"])
    out = capsys.readouterr().out
    assert "meeting: new=3" in out and "PAY-1: 1" in out and "lark_msg: not configured" in out

    cli.main(["pending", "PAY-1", "--json"])
    pending = json.loads(capsys.readouterr().out)
    assert [p["title"] for p in pending] == ["PAY-1 weekly"]

    cli.main(["done", "PAY-1"])
    cli.main(["sync"])
    assert "No requirement got new sources" in capsys.readouterr().out

    cli.main(["inbox", "--json"])
    inbox = json.loads(capsys.readouterr().out)
    assert [i["title"] for i in inbox] == ["Random"]
    cli.main(["link", inbox[0]["id"], "PAY-1"])
    cli.main(["search", "flag", "--req", "PAY-1", "--json"])
    hits = json.loads(capsys.readouterr().out.split("\n", 1)[1])
    assert hits[0]["reqs"] == ["PAY-1"]


def test_sync_gate_and_batch_speed(root, tmp_path, capsys):
    notes = tmp_path / "notes"
    notes.mkdir()
    for i in range(2000):
        (notes / f"n{i}.md").write_text(f"# note {i}\n\nbody {i}")
    cli.main(["init"])
    (root / "config.yaml").write_text(f"meetings:\n  dirs: [{notes}]\n")
    import time
    t = time.time()
    cli.main(["sync", "--gate"])
    assert time.time() - t < 15
    out = capsys.readouterr().out
    assert "new=2000" in out and out.strip().endswith('{"wakeAgent": false}')
    cli.main(["sync", "--gate"])
    assert "meeting: no changes" in capsys.readouterr().out


def test_req_validation(root):
    with pytest.raises(ValueError):
        dossier.create(root, "../evil", "x")
    dossier.create(root, "OK-1", "x")
    with pytest.raises(ValueError):
        dossier.create(root, "OK-1", "x")

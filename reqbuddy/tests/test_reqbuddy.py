"""Synthetic fixtures only: the real examples are private customer mail and chats."""
import io
import json
from email.message import EmailMessage
from pathlib import Path

import pymupdf
import pytest
from PIL import Image

from reqbuddy import cli
from reqbuddy.cases import DEMO_INPUTS, CasesError, Report
from reqbuddy.config import Config, Person, Provider, defaults
from reqbuddy.extract import Source, clean, expand, extract, rtf_to_text
from reqbuddy.llm import strip_thinking
from reqbuddy.prompt import build, default_system_prompt


def png(w=200, h=120, color=(200, 30, 30)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, "PNG")
    return buf.getvalue()


def make_pdf(path: Path, lines: list[str], with_image: bool = False) -> Path:
    doc = pymupdf.open()
    page = doc.new_page()
    y = 72
    for ln in lines:
        page.insert_text((72, y), ln)
        y += 20
    if with_image:
        page.insert_image(pymupdf.Rect(72, y + 10, 272, y + 130), stream=png())
    doc.save(path)
    return path


@pytest.fixture
def cfg() -> Config:
    c = defaults()
    c.people = [Person("Jane Doe", "CTO", "jane@example.com"), Person("Me", "developer", me=True)]
    return c


def test_chat_pdf_is_a_conversation_with_picture_markers(tmp_path):
    p = make_pdf(tmp_path / "chat.pdf", ["Team chat", "To view more chat history, you can Return to Chat",
                                         "Jane 10:00", "please fix the total"], with_image=True)
    s = extract(p)
    assert s.kind == "chat" and s.is_conversation
    assert "please fix the total" in s.text and "[picture]" in s.text
    assert [pic.label for pic in s.pictures] == ["Page 1"]
    assert max(s.pictures[0].size) == 2400  # rendered sharp; downscaled only when sent


def test_plain_pdf_is_a_possible_test_input(tmp_path):
    s = extract(make_pdf(tmp_path / "po.pdf", ["PURCHASE ORDER", "Total Amount 100.00"]))
    assert s.kind == "pdf" and not s.is_conversation


def test_rtfd_marks_images_in_place_dedups_and_skips_separators(tmp_path):
    d = tmp_path / "mail.rtfd"
    d.mkdir()
    (d / "1__#$!@%!#__unknown.png").write_bytes(png())
    (d / "copy.png").write_bytes(png())                     # same bytes: quoted reply
    (d / "separator.png").write_bytes(png(20, 2))           # too small: a separator
    g = lambda n: rb"{{\NeXTGraphic " + n + rb" \width320 \height320 \appleattachmentpadding0" + b"\n}\xac}"  # noqa: E731
    (d / "TXT.rtf").write_bytes(
        rb"{\rtf1\ansi\ansicpg1252{\fonttbl\f0 Helvetica;}{\colortbl;\red255\green255\blue255;}"
        rb"\f0 From: A\par Why MISMATCH\uc0\u65292 \u19981 \u26159 ?\par " + g(rb"1__#$!@%!#__unknown.png")
        + rb"\par ====================\par " + g(b"separator.png") + rb"\par Reply\par " + g(b"copy.png") + rb"\par Done}")
    s = extract(d)
    assert s.kind == "email"
    assert "Why MISMATCH，不是?" in s.text
    assert "[Image 1]" in s.text and "[same as Image 1]" in s.text and "[Image 2]" not in s.text
    assert len(s.pictures) == 1 and s.pictures[0].path.endswith("unknown.png")
    assert "Helvetica" not in s.text


def test_rtf_hex_bytes_use_the_code_page():
    text, _ = rtf_to_text(rb"{\rtf1\ansi\ansicpg1252 caf\'e9\par}")
    assert text.strip() == "café"


def test_eml_text_and_images(tmp_path):
    m = EmailMessage()
    m["From"], m["Subject"] = "a@example.com", "PO check"
    m.set_content("The unit price is wrong.")
    m.add_attachment(png(), maintype="image", subtype="png", filename="shot.png")
    (tmp_path / "m.eml").write_bytes(m.as_bytes())
    s = extract(tmp_path / "m.eml")
    assert s.kind == "email" and "Subject: PO check" in s.text and "unit price is wrong" in s.text
    assert len(s.pictures) == 1


def test_expand_walks_folders_but_keeps_rtfd_whole(tmp_path):
    (tmp_path / "a.txt").write_text("x")
    (tmp_path / "b.rtfd").mkdir()
    (tmp_path / "b.rtfd" / "TXT.rtf").write_text("{\\rtf1 x}")
    (tmp_path / "ignore.bin").write_text("x")
    assert [p.name for p in expand([tmp_path])] == ["a.txt", "b.rtfd"]


def test_clean_collapses_noise():
    assert clean("a b\n\n\n\n" + "=" * 60 + "\n") == "a b\n\n" + "=" * 20


def test_prompt_hides_conversation_paths_and_keeps_test_input_paths(cfg, tmp_path):
    chat = Source(tmp_path / "Chat between Jane and Me.pdf", "chat", "Jane: fix it", [])
    po = Source(tmp_path / "po.pdf", "pdf", "PURCHASE ORDER", [])
    built = build([chat, po], cfg, notes="item 2 is by design", send_images=True)
    user = built.messages[1]["content"]
    assert "Chat between Jane" not in user and "describes the request; never list it as a file" in user
    assert f"Path: {tmp_path / 'po.pdf'}" in user
    assert "My notes (authoritative" in user and "Jane Doe (also: jane@example.com) - CTO" in user
    assert built.messages[0]["content"] == default_system_prompt()


def test_prompt_images_limit_and_text_only(cfg, tmp_path):
    from reqbuddy.extract import Picture
    s = Source(tmp_path / "x.png", "image", "", [Picture(f"Image {i}", png(3000, 1000)) for i in range(3)])
    cfg.max_images = 2
    b = build([s], cfg, send_images=True, image_side=1600)
    images = [p for p in b.messages[1]["content"] if p["type"] == "image_url"]
    assert len(images) == 2 and b.dropped_images == 1 and "<image 1600x533>" in b.preview
    t = build([s], cfg, send_images=False)
    assert isinstance(t.messages[1]["content"], str) and t.image_count == 0


def test_case_report_source_and_rule(cfg):
    r = Report({"run": "abc123", "demo": "pdf_match", "case": "issues", "status": "passed",
                "matches_recording": True, "summary": {"differences": [1, 2]}, "diff": [], "problems": []})
    assert r.verdict == "passed · matches recording · 2 difference(s) · run abc123" and not r.inputs_incomplete
    b = build([r.source()], cfg)
    assert "case run (actual output of our system" in b.messages[1]["content"]
    assert "Case reports are observations" in b.messages[0]["content"]
    bad = Report({"run": "x", "demo": "pdf_match", "status": "failed", "problems": [{"kind": "bad_input"}]})
    assert bad.inputs_incomplete and bad.verdict.startswith("inputs incomplete")


def test_pdf_match_needs_two_distinct_pdfs(tmp_path):
    a, b = tmp_path / "a.pdf", tmp_path / "b.pdf"
    a.write_bytes(b"%PDF"), b.write_bytes(b"%PDF")
    DEMO_INPUTS["pdf_match"].validate([a, b])
    with pytest.raises(CasesError):
        DEMO_INPUTS["pdf_match"].validate([a])
    with pytest.raises(CasesError):
        DEMO_INPUTS["pdf_match"].validate([a, a])


def test_provider_lookup_and_locality():
    c = defaults()
    assert c.provider("gem").name == "Gemini" and c.provider().name == "Gemini"
    assert c.provider("local 35").is_local and not c.provider("gemini").is_local
    with pytest.raises(KeyError):
        c.provider("nope")
    assert Config.from_dict(json.loads(c.to_json())) == c


def test_strip_thinking():
    assert strip_thinking("<think>hmm</think>\n# Brief") == "# Brief"
    assert strip_thinking("hmm</think># Brief") == "# Brief"


def test_cli_dry_run_and_prompt(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("REQBUDDY_CONFIG", str(tmp_path / "config.json"))
    monkeypatch.setattr("reqbuddy.config.MAC_APP_SETTINGS", tmp_path / "none.json")
    (tmp_path / "note.txt").write_text("Please rename the column.")
    assert cli.main([str(tmp_path / "note.txt"), "--provider", "gemini", "--dry-run", "--images"]) == 0
    out = capsys.readouterr().out
    assert "Please rename the column." in out and "Write exactly one brief now." in out
    assert cli.main(["prompt"]) == 0 and "capable coding agent" in capsys.readouterr().out
    assert cli.main(["brief", "--provider", "nope", str(tmp_path / "note.txt")]) == 1

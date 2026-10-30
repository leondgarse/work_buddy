"""Score how well a model drives the work-buddy skill through Hermes.

Builds a throwaway dossier whose sources contain the hard cases (a decision a later meeting
overrides, an owner nobody states, a Chinese chat, an unrelated note), asks Hermes to update it
and answer a question, then checks context.md, timeline.md and the answer.

  uv run python scripts/eval_model.py --provider micl --model unsloth/Qwen3.8-27B
  uv run python scripts/eval_model.py            # Hermes' default model
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

SOURCES = {
    "2026-10-14_PAY-1-kickoff.md": (
        "# PAY-1 kickoff\n\n"
        "Alice: Refunds launch on Nov 3.\n"
        "Bob: I'll own the ledger migration.\n"
        "Carol: Can customers refund to a different card? Let's discuss later.\n"),
    "2026-10-21_PAY-1-weekly.vtt": (
        "WEBVTT\n\n1\n00:00:01.000 --> 00:00:04.000\n"
        "<v Alice>Change of plan: we move the refunds launch to Nov 10, behind a feature flag.</v>\n\n"
        "2\n00:00:04.000 --> 00:00:08.000\n"
        "<v Carol>Do partial refunds need finance approval? Nobody has decided yet.</v>\n\n"
        "3\n00:00:08.000 --> 00:00:10.000\n"
        "<v Bob>Refund to a different card is out for this release.</v>\n"),
    "2026-10-22_PAY-1-退款群.md": (
        "# PAY-1 退款 群聊\n\n"
        "[2026-10-22 10:02] 王伟: 退款接口的幂等键用 订单号+退款序号，已和支付团队确认。\n"
        "[2026-10-22 10:05] 李娜: 退款导出功能这期不做。\n"),
    "2026-10-23_offsite.md": "# Team offsite\n\nLunch is at 12:30. Bring a jacket.\n",
}

PROMPT = (
    "WB_HOME is {home}. Using the work-buddy skill: update the PAY-1 dossier from all of its pending "
    "sources (context.md and timeline.md), mark them done, then answer in two short lines: "
    "(1) When do refunds launch? (2) Who owns the launch itself?")


def section(text: str, name: str) -> str:
    m = re.search(rf"^## {name}\s*$(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
    return m.group(1) if m else ""


def has(text: str, *patterns: str) -> bool:
    return any(re.search(p, text, re.IGNORECASE) for p in patterns)


def score(home: Path, answer: str) -> dict[str, bool | float]:
    d = home / "requirements" / "PAY-1"
    ctx = (d / "context.md").read_text()
    timeline = (d / "timeline.md").read_text()
    decisions = section(ctx, "Decisions")
    nov10 = (r"nov(ember)?\.? ?10", r"11[-/]10", r"10 nov")
    nov3 = (r"nov(ember)?\.? ?3\b", r"11[-/]0?3\b", r"\b3 nov")
    bullets = [b for b in re.findall(r"^\s*- (.+)$", ctx, re.MULTILINE)
               if not re.match(r"(In|Out):\s*$|\(none", b)]
    cited = [b for b in bullets if re.search(r"\(sources/[^)]+\)", b)]
    cites_ok = all((d / c).exists() for b in cited for c in re.findall(r"\((sources/[^)]+)\)", b))
    pending = subprocess.run(["wb", "pending", "PAY-1", "--json"], capture_output=True, text=True,
                             env={**os.environ, "WB_HOME": str(home)}).stdout
    return {
        "launch_nov10_in_decisions": has(decisions, *nov10),
        "nov3_moved_to_superseded": has(section(ctx, "Superseded"), *nov3),
        "nov3_not_a_current_decision": not has(decisions, *nov3) or has(decisions, r"supersed|replac|moved|instead"),
        "idempotency_from_chinese_chat": has(ctx, r"幂等", r"idempot"),
        "export_out_of_scope": has(section(ctx, "Scope") + decisions, r"导出", r"export"),
        "other_card_out_of_scope": has(section(ctx, "Scope") + decisions, r"different card|other card|另一张"),
        "partial_refund_open_question": has(section(ctx, "Open questions"), r"partial"),
        "bob_owns_ledger_migration": has(section(ctx, "Owners & action items"), r"bob.*ledger|ledger.*bob"),
        "no_invented_ledger_due_date": not has(section(ctx, "Owners & action items"),
                                               r"ledger[^\n]*(due|by) (nov|oct|\d)"),
        "offsite_note_ignored": not has(ctx + timeline, r"offsite|lunch|jacket"),
        "timeline_has_3_events": len(re.findall(r"^- \d{4}-\d{2}-\d{2}", timeline, re.MULTILINE)) >= 3,
        "citation_rate": round(len(cited) / len(bullets), 2) if bullets else 0.0,
        "citations_resolve": bool(cited) and cites_ok,
        "marked_done": json.loads(pending or "[]") == [],
        "answer_nov10": has(answer, *nov10),
        "answer_owner_unstated": has(answer, r"not (stated|specified|named|mentioned|assigned)|unresolved|unknown|no (one|owner)|unassigned"),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider")
    ap.add_argument("--model")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--keep", action="store_true", help="keep the temp WB_HOME for inspection")
    args = ap.parse_args()

    home = Path(tempfile.mkdtemp(prefix="wb-eval-"))
    env = {**os.environ, "WB_HOME": str(home)}
    notes = home / "notes"
    notes.mkdir()
    for name, text in SOURCES.items():
        (notes / name).write_text(text)
    run = lambda *a: subprocess.run(["wb", *a], env=env, check=True, capture_output=True, text=True)
    run("init")
    (home / "config.yaml").write_text(f"meetings:\n  dirs: [{notes}]\n")
    run("req", "new", "PAY-1", "--title", "Refunds", "--alias", "refunds", "--alias", "退款")
    run("sync")

    cmd = ["hermes", "chat", "-Q", "-s", "work-buddy", "-q", PROMPT.format(home=home)]
    if args.provider:
        cmd += ["--provider", args.provider]
    if args.model:
        cmd += ["-m", args.model]
    start = time.time()
    try:
        proc = subprocess.run(cmd, env=env, cwd=home, capture_output=True, text=True, timeout=args.timeout)
        answer, status = proc.stdout, f"exit {proc.returncode}"
    except subprocess.TimeoutExpired as e:
        answer, status = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "timeout"
    elapsed = round(time.time() - start)

    checks = score(home, answer)
    passed = sum(v is True for v in checks.values())
    total = sum(isinstance(v, bool) for v in checks.values())
    print(json.dumps({"model": args.model or "(hermes default)", "provider": args.provider or "(default)",
                      "status": status, "seconds": elapsed, "passed": f"{passed}/{total}", **checks},
                     ensure_ascii=False, indent=2))
    print("--- answer (tail) ---\n" + "\n".join(answer.strip().splitlines()[-6:]))
    if args.keep:
        print(f"kept: {home}")
    else:
        shutil.rmtree(home)


if __name__ == "__main__":
    main()

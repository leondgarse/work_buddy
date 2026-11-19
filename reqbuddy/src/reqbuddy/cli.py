"""reqbuddy: emails, chat exports and screenshots in; a short task prompt for a coding agent out.

  reqbuddy brief chat.pdf shot.png             # brief to stdout (`reqbuddy chat.pdf …` works too)
  reqbuddy brief mail.rtfd -n "2 is by design" -o brief.md --copy
  reqbuddy brief chat.pdf --demo-run pdf_match --demo-file quote.pdf --demo-file po.pdf
  reqbuddy cases list | health | run pdf_match/issues | demo pdf_match quote.pdf po.pdf
  reqbuddy models -p gemini        reqbuddy prompt        reqbuddy config [init|path|import-mac]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import config as cfgmod
from .cases import DEMO_INPUTS, CasesAPI, CasesError
from .extract import ExtractError, expand, extract
from .llm import Client, LLMError
from .describe import parse_spec, transcriber
from .prompt import build, case_report_rule, default_system_prompt

COMMANDS = ("brief", "cases", "models", "prompt", "config")


def err(*a: object) -> None:
    print(*a, file=sys.stderr, flush=True)


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] not in COMMANDS and argv[0] not in ("-h", "--help", "--version"):
        argv.insert(0, "brief")
    ap = argparse.ArgumentParser(prog="reqbuddy", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version="reqbuddy " + __import__("reqbuddy").__version__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("brief", help="write one brief from the given files (they form ONE requirement)")
    b.add_argument("files", nargs="*", help="files or folders: .rtfd .eml .pdf images .txt .md .rtf")
    b.add_argument("-p", "--provider", help="provider name or prefix (see `reqbuddy config`)")
    b.add_argument("-m", "--model", help="override the provider's model")
    b.add_argument("-n", "--notes", default="", help="my notes: override the sources (e.g. '2 is by design')")
    b.add_argument("--notes-file", type=Path)
    b.add_argument("-o", "--output", type=Path, help="also write the brief to this file")
    b.add_argument("--copy", action="store_true", help="also copy the brief to the clipboard")
    b.add_argument("--dry-run", action="store_true", help="print the prompt instead of calling the model")
    g = b.add_mutually_exclusive_group()
    g.add_argument("--images", dest="vision", action="store_const", const="images", help="send images")
    g.add_argument("--text", dest="vision", action="store_const", const="text", help="send text only")
    b.add_argument("--extra", help='JSON merged into the request, e.g. \'{"temperature":0.3}\'')
    b.add_argument("--system", type=Path, help="system prompt file (A/B tests)")
    b.add_argument("--image-side", type=int, help="long side (px) of images sent")
    b.add_argument("--transcriber", metavar="PROVIDER[|MODEL]",
                   help="for a text-only model: a vision model that transcribes each picture first "
                        "(default: config `transcriber`; 'none' to drop pictures)")
    b.add_argument("--case", action="append", default=[], metavar="DEMO/ID", help="run a recorded case first")
    b.add_argument("--demo-run", metavar="DEMO", help="run our pipeline on --demo-file inputs first")
    b.add_argument("--demo-file", action="append", default=[], type=Path, metavar="FILE",
                   help="input for --demo-run, in slot order (pdf_match: A quotation, then B PO)")
    b.add_argument("--strict", action="store_true", help="recorded cases: any diff from the recording fails")
    b.add_argument("--case-events", action="store_true", help="include the pipeline's intermediate stages")
    b.add_argument("--cases-url", help="cases API base URL (default from config)")

    c = sub.add_parser("cases", help="the cases API: list, health, run a recorded case, run a demo on files")
    c.add_argument("action", choices=["list", "health", "run", "demo"])
    c.add_argument("args", nargs="*", help="run: DEMO/ID; demo: DEMO FILE...; list: [DEMO]")
    c.add_argument("--strict", action="store_true")
    c.add_argument("--events", action="store_true")
    c.add_argument("--url", help="cases API base URL (default from config)")

    m = sub.add_parser("models", help="list a provider's models and whether they take images")
    m.add_argument("-p", "--provider")

    pr = sub.add_parser("prompt", help="print the built-in system prompt")
    pr.add_argument("--case-rule", action="store_true", help="also print the rule added for case reports")

    cf = sub.add_parser("config", help="show the config (keys hidden), or init / path / import-mac")
    cf.add_argument("action", nargs="?", default="show", choices=["show", "init", "path", "import-mac"])
    cf.add_argument("--force", action="store_true", help="init: overwrite an existing config")

    a = ap.parse_args(argv)
    try:
        return {"brief": cmd_brief, "cases": cmd_cases, "models": cmd_models, "prompt": cmd_prompt,
                "config": cmd_config}[a.cmd](a)
    except (CasesError, LLMError, ExtractError, KeyError) as e:
        err(f"reqbuddy: {e}")
        return 1
    except KeyboardInterrupt:
        err("stopped")
        return 130


def cmd_brief(a: argparse.Namespace) -> int:
    cfg = cfgmod.load()
    if a.demo_file and not a.demo_run:
        raise CasesError("--demo-file needs --demo-run")
    sources = []
    for p in expand(a.files):
        try:
            s = extract(p)
        except ExtractError as e:
            err(f"skip {p.name}: {e}")
            continue
        sources.append(s)
        err(f"read {p.name}: {s.kind}, {len(s.text)} chars, {len(s.pictures)} picture(s)")
    if a.files and not sources:
        raise ExtractError("none of the given files could be read")

    reports = run_cases(cfg, a)
    sources += [r.source(a.demo_file if (r.raw.get("case") is None and a.demo_run) else None) for r in reports]
    if not sources:
        raise ExtractError("nothing to read: give files, --case or --demo-run")

    if reports and not a.provider:   # case reports come from customer documents: stay local unless told
        local = next((p for p in cfg.providers if p.is_local), None)
        if not local:
            raise KeyError("case reports hold customer data: choose --provider explicitly (no local one configured)")
        provider = local
    else:
        provider = cfg.provider(a.provider)
    if a.model:
        provider.model = a.model
    if a.vision:
        provider.vision = a.vision
    if a.extra:
        provider.extra = json.loads(a.extra)
    notes = a.notes + ("\n" + a.notes_file.read_text() if a.notes_file else "")
    system = a.system.read_text() if a.system else None

    client = Client(provider)
    send_images = client.accepts_images()
    spec = a.transcriber if a.transcriber is not None else cfg.transcriber
    tr = None
    if not send_images and spec and spec.lower() != "none":
        tp = parse_spec(cfg, spec)
        if reports and not tp.is_local and not a.provider:
            raise KeyError("case reports hold customer data: the transcriber must be local too")
        tr = transcriber(tp, a.image_side or cfg.image_side, progress=err)
    built = build(sources, cfg, notes, send_images, a.image_side, system, transcribe=tr)
    err(f"provider={provider.name} model={provider.model} "
        + (f"images={built.image_count} sent" if send_images
           else f"text only, {built.image_count} picture(s) transcribed" if tr else "text only (no images)"))
    if a.dry_run:
        print(built.preview)
        return 0

    t0, thinking = time.monotonic(), 0
    def on_delta(_c: str, r: str) -> None:
        nonlocal thinking
        thinking += len(r)
    brief = client.complete(built.messages, on_delta)
    if reports:
        brief += "\n\n## Case runs\n" + "".join(f"- {r.label}: run `{r.run}` — {r.verdict}\n" for r in reports)
    print(brief)
    if a.output:
        a.output.write_text(brief + "\n")
        err(f"saved {a.output}")
    if a.copy:
        copy_to_clipboard(brief)
    err(f"done in {time.monotonic() - t0:.1f}s (reasoning chars: {thinking})")
    return 0


def run_cases(cfg: cfgmod.Config, a: argparse.Namespace) -> list:
    if not a.case and not a.demo_run:
        return []
    api = CasesAPI(a.cases_url or cfg.cases_url)
    reports = []
    for key in a.case:
        demo, _, cid = key.partition("/")
        if not cid:
            raise CasesError("--case must be DEMO/ID")
        r = api.run_case(demo, cid, a.strict, a.case_events, progress=lambda s, k=key: err(f"{k}: {s}"))
        if r.inputs_incomplete:
            raise CasesError(f"{key}: {r.verdict}")
        reports.append(r)
    if a.demo_run:
        r = api.run_demo(a.demo_run, a.demo_file, a.case_events, progress=lambda s: err(f"{a.demo_run}: {s}"))
        if r.inputs_incomplete:
            raise CasesError(f"{a.demo_run}: {r.verdict}")
        reports.append(r)
    return reports


def cmd_cases(a: argparse.Namespace) -> int:
    api = CasesAPI(a.url or cfgmod.load().cases_url)
    if a.action == "health":
        print(json.dumps(api.health(), indent=1, ensure_ascii=False))
        return 0
    if a.action == "list":
        for c in api.cases(a.args[0] if a.args else None):
            print(f"{c['demo'] + '/' + c['id']:<28} {'live' if c.get('live') else 'down':<5} {c.get('title', '')}")
        print("\nfile inputs for `cases demo` / `brief --demo-run`:")
        for d in DEMO_INPUTS.values():
            print(f"  {d.demo:<10} {', '.join(d.labels[:3])}{' …' if len(d.labels) > 3 else ''}")
        return 0
    if a.action == "run":
        if len(a.args) != 1 or "/" not in a.args[0]:
            raise CasesError("usage: reqbuddy cases run DEMO/ID")
        demo, _, cid = a.args[0].partition("/")
        r = api.run_case(demo, cid, a.strict, a.events, progress=err)
    else:
        if len(a.args) < 2:
            raise CasesError("usage: reqbuddy cases demo DEMO FILE...")
        r = api.run_demo(a.args[0], [Path(f).expanduser() for f in a.args[1:]], a.events, progress=err)
    print(json.dumps(r.raw, indent=1, ensure_ascii=False))
    err(r.verdict)
    return 0 if r.status == "passed" else 1


def cmd_models(a: argparse.Namespace) -> int:
    p = cfgmod.load().provider(a.provider)
    for mi in Client(p).list_models():
        mark = {True: "images", False: "text", None: "?"}[mi.accepts_images]
        print(f"{'*' if mi.id == p.model else ' '} {mi.id:<50} {mark}")
    return 0


def cmd_prompt(a: argparse.Namespace) -> int:
    print(default_system_prompt())
    if a.case_rule:
        print("\n" + case_report_rule())
    return 0


def cmd_config(a: argparse.Namespace) -> int:
    path = cfgmod.config_path()
    if a.action == "path":
        print(path)
        return 0
    if a.action in ("init", "import-mac"):
        if path.exists() and not a.force:
            raise KeyError(f"{path} exists; use --force to overwrite")
        cfg = cfgmod.import_mac_app() if a.action == "import-mac" else cfgmod.defaults()
        if cfg is None:
            raise KeyError(f"no macOS app settings at {cfgmod.MAC_APP_SETTINGS}")
        err(f"wrote {cfgmod.save(cfg)}")
        return 0
    cfg = cfgmod.load()
    shown = json.loads(cfg.to_json())
    for p in shown["providers"]:
        if p.get("api_key"):
            p["api_key"] = "***"
    print(f"# {path}{'' if path.exists() else ' (not written yet: defaults)'}")
    print(json.dumps(shown, indent=2, ensure_ascii=False))
    return 0


def copy_to_clipboard(text: str) -> None:
    for tool in (["pbcopy"], ["wl-copy"], ["xclip", "-selection", "clipboard"]):
        if shutil.which(tool[0]):
            subprocess.run(tool, input=text.encode(), check=False)
            err("copied to clipboard")
            return
    err("no clipboard tool found (pbcopy / wl-copy / xclip)")

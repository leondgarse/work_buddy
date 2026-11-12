#!/usr/bin/env python3
"""Benchmark ReqBuddy briefs: run reqcli over cases x configs, score each brief with per-case checks.

Cases are private (customer emails / chats), so they live outside the repo, by default in
../requirement_example/bench/*.json. Scoring is local regex checks: nothing is sent to a judge.

Case file:
{
  "id": "short-name",
  "inputs": ["../relative/to/case/file.pdf", ...],
  "notes": "optional 'My notes' text",
  "reference": "the brief we consider right (for reading side by side; not scored)",
  "checks": [
    {"name": "mentions anonymized", "all": ["anonymi[sz]ed"]},           # every regex must match
    {"name": "privacy is tentative", "any": ["consider[^\\n]*privacy"]},  # one of them must match
    {"name": "no names", "none": ["Jane|John"]},                        # none may match
    {"name": "short", "max_words": 300}
  ]
}
Regexes are case-insensitive and run on the whole brief.

Config: NAME=provider[|model][|key=value...], keys: extra (JSON), system (prompt file), image_side (px), mode (images|ocr)
  python3 bench/run_bench.py -c "35b=MICL Qwen3.6 :18010" -c "35b-t03=MICL Qwen3.6 :18010||extra={\"temperature\":0.3}" -n 2
"""
import argparse, json, os, re, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REQCLI = HERE.parent / "dist" / "reqcli"


def parse_config(s):
    name, _, rest = s.partition("=")
    parts = rest.split("|")
    cfg = {"name": name, "provider": parts[0], "model": parts[1] if len(parts) > 1 and parts[1] else None}
    for kv in parts[2:]:
        k, _, v = kv.partition("=")
        cfg[k] = v
    return cfg


def run_one(case, case_dir, cfg):
    cmd = [str(REQCLI), "--provider", cfg["provider"]]
    if cfg.get("model"): cmd += ["--model", cfg["model"]]
    if cfg.get("extra"): cmd += ["--extra", cfg["extra"]]
    if cfg.get("system"): cmd += ["--system", cfg["system"]]
    if cfg.get("image_side"): cmd += ["--image-side", cfg["image_side"]]
    if cfg.get("mode") == "ocr": cmd += ["--ocr"]
    if cfg.get("mode") == "images": cmd += ["--images"]
    if case.get("notes"): cmd += ["--notes", case["notes"]]
    cmd += [str((case_dir / p).resolve()) for p in case["inputs"]]
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.stdout.strip(), p.stderr, time.time() - t0, p.returncode


def score(brief, checks):
    res = []
    for c in checks:
        f = lambda rx: re.search(rx, brief, re.I | re.S) is not None
        if "all" in c: ok = all(f(r) for r in c["all"])
        elif "any" in c: ok = any(f(r) for r in c["any"])
        elif "none" in c: ok = not any(f(r) for r in c["none"])
        elif "max_words" in c: ok = len(re.findall(r"\S+", brief)) <= c["max_words"]
        else: ok = False
        res.append((c["name"], ok))
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--config", action="append", required=True)
    ap.add_argument("-n", "--repeats", type=int, default=1)
    ap.add_argument("--cases", default=str(HERE.parent.parent / "requirement_example" / "bench"))
    ap.add_argument("--only", help="regex on case id")
    ap.add_argument("--out", help="results dir (default: <cases>/results/<timestamp>)")
    a = ap.parse_args()

    case_dir = Path(a.cases)
    cases = [json.loads(p.read_text()) | {"_file": p} for p in sorted(case_dir.glob("*.json"))]
    cases = [c for c in cases if c.get("checks") and (not a.only or re.search(a.only, c["id"]))]
    if not cases: sys.exit(f"no scored cases in {case_dir}")
    out = Path(a.out) if a.out else case_dir / "results" / time.strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=True)
    configs = [parse_config(s) for s in a.config]

    rows = []
    for cfg in configs:
        for case in cases:
            for r in range(a.repeats):
                brief, log, secs, rc = run_one(case, case["_file"].parent, cfg)
                tag = f"{cfg['name']}__{case['id']}__{r + 1}"
                (out / f"{tag}.md").write_text(brief + "\n")
                (out / f"{tag}.log").write_text(log)
                res = score(brief, case["checks"]) if rc == 0 and brief else [(c["name"], False) for c in case["checks"]]
                passed = sum(ok for _, ok in res)
                failed = [n for n, ok in res if not ok]
                rows.append({"config": cfg["name"], "case": case["id"], "run": r + 1, "passed": passed,
                             "total": len(res), "secs": round(secs), "rc": rc, "failed": failed,
                             "words": len(brief.split())})
                print(f"{cfg['name']:<14} {case['id']:<18} #{r + 1}  {passed}/{len(res)}  {secs:5.0f}s"
                      + (f"  rc={rc}" if rc else "") + (f"  failed: {', '.join(failed)}" if failed else ""), flush=True)

    (out / "results.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2))
    print("\nconfig          mean score   mean secs")
    for cfg in configs:
        rs = [r for r in rows if r["config"] == cfg["name"]]
        sc = sum(r["passed"] / r["total"] for r in rs) / len(rs)
        print(f"{cfg['name']:<14}  {sc:6.0%}      {sum(r['secs'] for r in rs) / len(rs):6.0f}")
    print(f"\nbriefs and logs: {out}")


if __name__ == "__main__":
    main()

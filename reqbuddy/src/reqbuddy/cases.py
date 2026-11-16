"""Client for the internal cases API: run recorded demo cases, or our pipeline on our own files, and
turn the report into a source for the brief ("Actual result …")."""
from __future__ import annotations

import base64
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .extract import Source

TERMINAL = ("passed", "failed", "error")


class CasesError(Exception):
    pass


@dataclass(frozen=True)
class DemoInputs:
    demo: str
    labels: tuple[str, ...]
    minimum: int

    def validate(self, files: list[Path]) -> None:
        if not self.minimum <= len(files) <= len(self.labels):
            raise CasesError(f"inputs incomplete: {self.demo} takes {self.minimum}-{len(self.labels)} file(s), "
                             f"in order: {', '.join(self.labels)}")
        if len({f.resolve() for f in files}) != len(files):
            raise CasesError("inputs incomplete: use a different file for each slot")
        missing = [str(f) for f in files if not f.is_file()]
        if missing:
            raise CasesError(f"inputs incomplete: not found: {', '.join(missing)}")
        if self.demo == "pdf_match" and any(f.suffix.lower() != ".pdf" for f in files):
            raise CasesError("inputs incomplete: A and B must both be PDFs (A = our quotation, B = the customer's PO)")


DEMO_INPUTS = {d.demo: d for d in [
    DemoInputs("pdf_match", ("A: our quotation", "B: the customer's PO"), 2),
    DemoInputs("packing", tuple(f"document {i}" for i in range(1, 9)), 1),
    DemoInputs("logistics", ("RFQ",), 1),
    DemoInputs("office", ("document",), 1),
    DemoInputs("email", ("email",), 1),
]}


@dataclass
class Report:
    raw: dict

    run = property(lambda self: str(self.raw.get("run", "")))
    demo = property(lambda self: str(self.raw.get("demo", "")))
    status = property(lambda self: str(self.raw.get("status", "")))
    label = property(lambda self: f"{self.demo}/{self.raw.get('case') or 'custom'}")
    terminal = property(lambda self: self.status in TERMINAL)

    @property
    def inputs_incomplete(self) -> bool:
        if self.status == "error":
            return True
        return any((p or {}).get("kind") == "bad_input" for p in self.raw.get("problems") or [])

    @property
    def verdict(self) -> str:
        if self.inputs_incomplete:
            return ("inputs incomplete: check the files and their order, then retry. "
                    + json.dumps(self.raw.get("problems"), ensure_ascii=False))
        match = self.raw.get("matches_recording")
        baseline = {True: "matches recording", False: "differs from recording"}.get(match, "custom inputs")
        summary = self.raw.get("summary") or {}
        extra = ""
        if isinstance(summary.get("differences"), list):
            extra = f" · {len(summary['differences'])} difference(s)"
        elif isinstance(summary.get("failing"), list):
            extra = f" · {len(summary['failing'])} failing check(s)"
        return f"{self.status} · {baseline}{extra} · run {self.run}"

    def source(self, files: list[Path] | None = None) -> Source:
        """A virtual source: an observation from our own system, not a document to obtain."""
        dump = lambda k: json.dumps(self.raw.get(k), ensure_ascii=False, indent=1)  # noqa: E731
        text = (f"Actual result (case `{self.label}`): {self.verdict}\n"
                "This is an observation from our own system. Use it to assess whether the reported problem reproduces.\n"
                "Deliberate negative cases can match their recording while reporting differences. "
                "Do not infer a bug from status alone.\n"
                f"Run id: {self.run}\nStatus: {self.status}\nSummary: {dump('summary')}\n"
                f"Diff against recording: {dump('diff')}\nProblems: {dump('problems')}\n")
        if self.raw.get("events"):
            text += ("Intermediate stages (artifact paths belong to the server, not this machine):\n"
                     + json.dumps(self.raw["events"], ensure_ascii=False, indent=1) + "\n")
        if files:
            text += "Test inputs (in upload order):\n" + "".join(f"- {f.name}: {f}\n" for f in files)
        return Source(Path(f"/case-runs/{self.run}"), "case report", text)


class CasesAPI:
    def __init__(self, base_url: str, timeout: float = 60):
        u = urllib.parse.urlparse(base_url)
        if u.scheme not in ("http", "https") or not u.hostname or u.query or u.fragment:
            raise CasesError(f"invalid cases API URL: {base_url}")
        self.base = base_url.rstrip("/")
        self.timeout = timeout

    def _call(self, parts: list[str], method: str = "GET", query: dict | None = None, body: dict | None = None):
        if not all(re.fullmatch(r"[A-Za-z0-9_-]+", p) for p in parts):
            raise CasesError(f"invalid case identifier: {'/'.join(parts)}")
        url = self.base + "/api/" + "/".join(parts) + ("?" + urllib.parse.urlencode(query) if query else "")
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                data = r.read()
                if not data and r.headers.get("Location"):  # some servers answer 202 with only Location
                    return {"run": r.headers["Location"].rstrip("/").rsplit("/", 1)[-1]}
                return json.loads(data or b"{}")
        except urllib.error.HTTPError as e:
            raise CasesError(f"cases API HTTP {e.code}: {e.read()[:2000].decode(errors='replace')}") from e
        except OSError as e:
            raise CasesError(f"cases API unreachable at {self.base}: {e}") from e

    def health(self) -> dict:
        return self._call(["health"])

    def cases(self, demo: str | None = None) -> list[dict]:
        return self._call(["cases"], query={"demo": demo} if demo else None).get("cases", [])

    def detail(self, demo: str, case_id: str) -> dict:
        return self._call(["cases", demo, case_id])

    def report(self, run: str, events: bool = False) -> Report:
        return Report(self._call(["runs", run], query={"events": 1} if events else None))

    def _finish(self, started: dict, events: bool, progress: Callable[[str], None] | None,
                poll: float = 1.0, timeout: float = 1800) -> Report:
        run = started.get("run")
        if not run:
            raise CasesError(f"unexpected response: {started}")
        deadline, last = time.monotonic() + timeout, ""
        while True:
            rep = self.report(run, events)
            if progress and rep.status != last:
                progress(f"{rep.status} · run {run}")
                last = rep.status
            if rep.terminal:
                return rep
            if time.monotonic() > deadline:
                raise CasesError(f"run {run} still not finished after {timeout:.0f}s; it may still be running")
            time.sleep(poll)

    def run_case(self, demo: str, case_id: str, strict: bool = False, events: bool = False,
                 progress: Callable[[str], None] | None = None) -> Report:
        q = {"wait": 0, "strict": int(strict), **({"events": 1} if events else {})}
        return self._finish(self._call(["cases", demo, case_id, "run"], "POST", q, {}), events, progress)

    def run_demo(self, demo: str, files: list[Path], events: bool = False,
                 progress: Callable[[str], None] | None = None) -> Report:
        """Our pipeline on our own files. The API runs on another machine, so files go up as base64."""
        spec = DEMO_INPUTS.get(demo)
        if not spec:
            raise CasesError(f"no file inputs known for demo {demo!r}; have: {', '.join(DEMO_INPUTS)}")
        spec.validate(files)
        body = {"files": [{"name": f.name, "base64": base64.b64encode(f.read_bytes()).decode()} for f in files]}
        q = {"wait": 0, **({"events": 1} if events else {})}
        return self._finish(self._call(["demos", demo, "run"], "POST", q, body), events, progress)

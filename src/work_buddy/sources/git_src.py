"""Commits from local git clones: one item per commit, with the touched paths for path-based linking."""

from __future__ import annotations

import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from ..model import Item
from . import NotConfigured, days_ago

_FIELD, _RECORD = "\x1f", "\x1e"
_FORMAT = _RECORD + _FIELD.join(["%H", "%an", "%ae", "%aI", "%cI", "%s", "%b"]) + _FIELD


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout


def web_url(remote: str) -> str:
    """https URL of a GitHub/GitLab-style remote, or '' if it can't be derived."""
    remote = remote.strip().removesuffix(".git")
    m = re.match(r"git@([^:]+):(.+)", remote) or re.match(r"ssh://git@([^/:]+)(?::\d+)?/(.+)", remote)
    if m:
        return f"https://{m.group(1)}/{m.group(2)}"
    return remote if remote.startswith("https://") else ""


def parse_log(out: str, repo: Path, base_url: str) -> list[tuple[Item, str]]:
    """Parse `git log` output in _FORMAT; returns (item, committer date) pairs."""
    items = []
    for record in out.split(_RECORD):
        if not record.strip():
            continue
        sha, name, email, adate, cdate, subject, body, files = record.split(_FIELD, 7)
        paths = [p for p in files.strip().splitlines() if p]
        text = body.strip()
        if paths:
            text += ("\n\n" if text else "") + "Files:\n" + "\n".join(f"- {p}" for p in paths[:200])
        items.append((Item(
            id=f"git:{repo.name}:{sha}",
            source="git",
            title=f"[{repo.name}] {subject}",
            body=text,
            ts=adate,
            author=f"{name} <{email}>",
            url=f"{base_url}/commit/{sha}" if base_url else "",
            participants=[email.lower()],
            refs={"repo": str(repo), "paths": paths, "sha": sha},
        ), cdate))
    return items


def fetch(cfg: dict, store, reqs):
    gcfg = cfg.get("git") or {}
    repos = gcfg.get("repos") or []
    if not repos:
        raise NotConfigured
    for repo_ref in repos:
        repo = Path(repo_ref).expanduser().resolve()
        key = f"git:{repo}"
        since = store.get_cursor(key) or days_ago(int(gcfg.get("since_days", 30))).isoformat()
        try:
            base_url = web_url(_git(repo, "remote", "get-url", "origin"))
        except subprocess.CalledProcessError:
            base_url = ""
        out = _git(repo, "log", f"--since={since}", "--name-only", f"--pretty=format:{_FORMAT}")
        newest = since
        for item, cdate in parse_log(out, repo, base_url):
            # Compare in UTC: committer dates carry their own offsets.
            newest = max(newest, datetime.fromisoformat(cdate).astimezone(timezone.utc).isoformat())
            yield item
        store.set_cursor(key, newest)

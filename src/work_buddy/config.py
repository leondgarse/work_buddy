"""Locating the data root and loading config.yaml (with ${ENV} expansion and an optional .env)."""

from __future__ import annotations

import os
import re
from pathlib import Path

import yaml

_ENV_REF = re.compile(r"\$\{(\w+)\}")


def home() -> Path:
    return Path(os.environ.get("WB_HOME", "~/.work_buddy")).expanduser()


def _load_dotenv(path: Path) -> None:
    """Set KEY=VALUE lines from path into os.environ, without overriding what is already set."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def _expand(value):
    if isinstance(value, str):
        return _ENV_REF.sub(lambda m: os.environ.get(m.group(1), ""), value)
    if isinstance(value, list):
        return [_expand(v) for v in value]
    if isinstance(value, dict):
        return {k: _expand(v) for k, v in value.items()}
    return value


def load_config(root: Path) -> dict:
    _load_dotenv(root / ".env")
    path = root / "config.yaml"
    if not path.exists():
        return {}
    return _expand(yaml.safe_load(path.read_text()) or {})


CONFIG_TEMPLATE = """\
# work_buddy sources. Secrets can live in .env next to this file and be referenced as ${VAR}.
# Delete or leave empty any section you don't use.

lark:
  domain: feishu            # feishu (open.feishu.cn) or lark (open.larksuite.com)
  app_id: ${LARK_APP_ID}
  app_secret: ${LARK_APP_SECRET}
  since_days: 14            # history to pull on the first sync of a chat
  chats: []                 # chat ids (oc_...) the bot is a member of
  docs: []                  # doc/wiki URLs or tokens always synced (requirements' lark_docs are added)

email:
  host: ""                  # e.g. imap.gmail.com
  port: 993
  user: ${EMAIL_USER}
  password: ${EMAIL_PASSWORD}
  folders: [INBOX]
  since_days: 14

git:
  since_days: 30
  repos: []                 # local clones, e.g. ~/workspace/project-x

meetings:
  dirs: []                  # folders of transcripts (.txt .md .vtt .srt); file names may start with YYYY-MM-DD
"""

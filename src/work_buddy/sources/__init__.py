"""Source connectors. Each exposes fetch(cfg, store, reqs) yielding Items and advancing its own
cursor only after everything was yielded, so an interrupted sync simply re-fetches."""

from datetime import datetime, timedelta, timezone


class NotConfigured(Exception):
    pass


def days_ago(days: int) -> datetime:
    return datetime.now(timezone.utc) - timedelta(days=days)

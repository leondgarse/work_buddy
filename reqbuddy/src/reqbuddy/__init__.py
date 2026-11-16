"""ReqBuddy: emails, chat exports and screenshots in; a short task prompt for a coding agent out.

The pipeline is plain functions so a CLI and, later, a web tool can share it:
    sources = [extract(p) for p in expand(paths)]
    built = build(sources, config, notes, send_images=...)
    text = Client(provider).complete(built.messages)
"""

__version__ = "0.2.0"

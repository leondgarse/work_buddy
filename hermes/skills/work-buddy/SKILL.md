---
name: work-buddy
description: "Requirement context: gather email, git, meetings, Lark into cited dossiers; answer questions."
version: 0.1.0
author: work_buddy
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Requirements, Context, Lark, Feishu, Email, Git, Meetings, Search]
    related_skills: [meeting-action-items, document-to-action-items]
prerequisites:
  commands: [wb]
---

# Work Buddy

Each requirement has a dossier under `$WB_HOME/requirements/<ID>/` (default `~/.work_buddy`):

| File | Who writes it | What it is |
|---|---|---|
| `meta.yaml` | you or the user | linking rules: aliases, people, lark_chats, lark_docs, email_threads, repos |
| `context.md` | you | current state of the requirement; every bullet cites `sources/<file>` |
| `timeline.md` | you | one line per event, oldest first |
| `sources/` | `wb` | symlinks to the raw items linked to this requirement (read-only) |

`wb` pulls sources, links items to requirements by rule, and indexes everything for search.
Run `wb <cmd> --help` for options. Add `--json` to any command for machine-readable output.

## When to Use

- "What's the current status / scope / decision on <requirement>?"
- "What did we agree about X?", "Who owns Y?", "Where was Z discussed?"
- "Start tracking requirement <ID>" or "add this doc/chat/transcript to <ID>"
- A cron run hands you `wb sync` output: update dossiers and triage the inbox.

## Answering questions

1. Find the requirement: `wb req list`. If the user didn't name one, `wb search <keywords>`
   and look at which requirements the hits are linked to.
2. Read `requirements/<ID>/context.md` first. It is the summary; trust it for the overview.
3. For specifics, exact wording, or anything context.md doesn't cover:
   `wb search <terms> --req <ID>` (add `--source email|lark_msg|lark_doc|git|meeting` to narrow),
   then read the files it prints.
4. Answer with citations: source type, date, and file path or URL. If sources conflict,
   prefer the newest one and say what it supersedes. If nothing answers it, say so.
   Don't fill the gap with a guess.

Search tips: terms are ANDed (falls back to OR when nothing matches). Quote phrases. Search both
the Chinese and English names of a concept. Terms of 1–2 characters use slower substring matching.

## Updating a dossier (after sync, or when asked)

For each requirement listed in the sync output, or the one the user names:

1. `wb pending <ID>` lists linked items not yet summarized, oldest first, with a count. Read **every**
   file it lists before writing anything. A later item often overrides an earlier one.
2. Check each item really belongs here. Auto-links on a single alias (`linked_by: auto:alias:...`)
   can be wrong: `wb unlink <item> <ID>` if it is unrelated.
3. Add one line per meaningful event to `timeline.md` in date order:
   `- 2026-10-21 [meeting] Decided to launch behind a flag (sources/2026-10-21_PAY-1-weekly_ab12cd34.md)`.
   Skip chit-chat.
4. Revise `context.md`. Keep its section structure, and replace the `_Last updated:` line with today's date.
   - Change existing bullets rather than appending duplicates.
   - When a newer source overrides an older decision, edit the decision and move the old one to
     **Superseded** with both citations.
   - Distinguish decided from proposed. An owner or due date only goes in when a source states it;
     otherwise write `unresolved`.
   - Every bullet ends with `(sources/<file>)`; use the file names as they appear under `sources/`.
   - An updated Lark doc shows up as pending again: its previous version is in
     `$WB_HOME/items/_history/`. Diff the two and record what changed.
5. `wb done <ID> <item-id> [<item-id> ...]` with the ids of the items you actually read and reflected.
   It prints what is still pending. If anything is, go back to step 1. Never mark items you haven't read.

## Triaging the inbox

`wb inbox` lists items no requirement claimed, with scored suggestions.
- It belongs to a requirement: `wb link <item> <ID>`, then update that dossier.
- It recurs (a chat, a thread, a keyword): add the rule to that requirement's `meta.yaml` and run
  `wb req relink <ID>`, so future items link on their own.
- It's noise: `wb ignore <item> [...]`.
- When unsure, leave it and ask the user. Don't guess links on weak evidence.

## Starting a requirement

1. `wb req new <ID> --title "<title>" --alias "<name>" --alias "<中文名>"`
2. Fill `meta.yaml` with what the user tells you: Lark doc URLs, dedicated chat ids, repo paths
   with the directories involved, key people.
3. `wb sync` (pulls newly listed docs and chats), then `wb req relink <ID>` (links items already stored).
4. Build the first `context.md` and `timeline.md` following "Updating a dossier".

Local files (exported transcripts, notes, PDFs converted to text):
`wb add <file> [--req <ID>] [--source meeting]`.

## Cron run

The prompt contains `wb sync` output. Update every requirement it lists, then triage the new inbox
items. Reply with a short digest: per requirement, what changed (decisions, new open questions,
changed owners or dates), plus inbox items that need the user. If a source reports `error`,
include it verbatim. If nothing needed doing, respond with [SILENT].

## Rules

- Never edit files under `sources/` or `items/`. They are the evidence.
- Never invent decisions, owners or dates.
- Don't paste whole documents into chat. Summarize and cite.

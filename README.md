# work_buddy

Collects email, git commits, meeting transcripts, Lark messages and Lark docs into one cited
dossier per requirement, and lets you (or a Hermes agent) query them.

- `wb` (this package) does the mechanical work: pull sources, link items to requirements by rule,
  index everything with SQLite FTS5 (trigram tokenizer, so Chinese works).
- The Hermes skill `hermes/skills/work-buddy` does the judgment: keeps `context.md` / `timeline.md`
  current, triages the inbox, answers questions with citations.

```
~/.work_buddy/                      ($WB_HOME)
  config.yaml  .env                 sources and secrets
  index.sqlite                      items, links, inbox, sync cursors, full-text index
  items/<source>/*.md               every pulled item, normalized; items/_history/ keeps old doc revisions
  requirements/<ID>/
    meta.yaml                       linking rules: aliases, people, chats, docs, threads, repo paths
    context.md  timeline.md         maintained by the agent, every bullet cites sources/
    sources/                        symlinks to the items linked to this requirement
```

## Setup

```sh
uv tool install -e ~/workspace/work_buddy      # puts `wb` in ~/.local/bin
wb init                                        # creates ~/.work_buddy/config.yaml
```

Already done on this machine: `skills.external_dirs` in `~/.hermes/config.yaml` points at
`hermes/skills` (backup in `config.yaml.bak-work-buddy`), and `hermes/scripts/wb_sync.sh` is
copied to `~/.hermes/scripts/`. Hermes only runs cron scripts from that folder and rejects symlinks,
so re-copy the script after you change it.

### Sources (edit `~/.work_buddy/config.yaml`, secrets in `~/.work_buddy/.env`)

- **Lark / Feishu:** create a self-built app in the developer console, enable the bot, and grant
  `im:message:readonly` (or `im:message.group_msg`), `im:chat:readonly`, `docx:document:readonly`,
  `wiki:wiki:readonly`, and optionally `contact:user.base:readonly` for sender names. Add the bot to
  each chat you list. For wiki docs, add the app as a collaborator on the doc or space. Then set
  `LARK_APP_ID` / `LARK_APP_SECRET` in `.env`. Messages close in time (30 min) become one
  conversation item.
- **Email:** IMAP, read-only (`BODY.PEEK`). For Gmail use an app password. Quoted replies are
  stripped, and replies inherit their thread root's links.
- **Git:** local clones; one item per commit with the touched paths.
- **Meetings:** folders of `.txt/.md/.vtt/.srt`, or one-off `wb add file.vtt --req ID`.

## Daily use

```sh
wb req new PAY-1 --title "Refunds" --alias refund --alias 退款
$EDITOR ~/.work_buddy/requirements/PAY-1/meta.yaml     # chats, docs, repos: [src/pay/]
wb sync && wb req relink PAY-1
wb pending PAY-1 / wb inbox / wb search 退款 审批 --req PAY-1
hermes chat -s work-buddy -q "update PAY-1 and summarize what changed"
```

Linking: mentioning the requirement id, a dedicated chat, a listed doc, a listed repo path, or the
email thread links automatically. An alias in the title links; an alias only in the body goes to the
inbox as a suggestion. Items matching nothing are indexed but don't clutter the inbox.

### Scheduled sync

```sh
hermes cron create "every 2h" --name work-buddy-sync --script wb_sync.sh --skill work-buddy \
  --deliver local "Update the requirement dossiers listed in the sync output and triage the inbox."
```

`wb sync --gate` ends with `{"wakeAgent": false}` when nothing needs attention, so quiet runs cost
no LLM tokens. Switch `--deliver` to `discord` (or `feishu:<chat_id>`) once that gateway is
connected.

## Not yet

- Lark Minutes transcripts (needs a user access token). Export them and use `wb add` for now.
- Sheets/Base docs (only docx is read).
- Embedding search: add `sqlite-vec` to `index.sqlite` when keyword search stops being enough
  (mostly for questions across requirements).

## Development

```sh
uv run pytest
```

# reqbuddy

Emails, Lark chat exports and screenshots in; a short task prompt for a coding agent (Claude Code,
Antigravity CLI) out. A command-line tool, written so a web tool can later call the same functions.

```bash
uv tool install -e ~/workspace/work_buddy/reqbuddy     # puts `reqbuddy` in ~/.local/bin

reqbuddy chat.pdf shot.png                    # the brief goes to stdout; progress goes to stderr
reqbuddy mail.rtfd -n "2 is by design" -o brief.md --copy
reqbuddy chat.pdf -p "local 35"               # pick a provider by name or prefix
reqbuddy chat.pdf --dry-run                   # show what the model would get
```

All files given in one run form **one** requirement and produce one brief. For the next requirement, run again
with its files.

## Inputs

- **Mail**: "Save As… Rich Text Format with attachments" (`.rtfd`) or `.eml`. Attachments are shown in place;
  quoted replies that repeat the same images are de-duplicated, and separators and icons are skipped.
- **Lark / Feishu chat exports** (`.pdf`): recognised by their "To view more chat history" header. Each page is
  sent as an image, so screenshots and highlights in the chat reach the model.
- **Other PDFs, screenshots, `.txt` / `.md` / `.rtf`**, or whole folders.
- **My notes** (`-n` / `--notes-file`) override the sources: items they call by design, already handled, or
  not needed are dropped.

Emails and chats reach the model without their file names (those carry people's names), labelled as describing
the request. Other files keep their paths, since they may be test inputs.

## Output

A short Markdown prompt: Title, Context, Requirements (bug: **Location** + **Issue** with the values seen;
change: one direct sentence), and Source files (only real test inputs, marked `[Should be provided]` when
missing). The agent reads the code itself, so the brief has no causes, implementation advice, acceptance
criteria or people's names. The prompt's rules are in `src/reqbuddy/system_prompt.txt`; each comes from a brief
that misled the agent:

- **Seen vs guessed.** What was seen is a fact. A guess about why (in chat or in a screenshot) is at most
  "Possible cause (unverified)", quoting the source's values. A claim nobody can check in the images is
  written as reported.
- **The asker's certainty is kept.** A manager's polite question is an instruction; "look into whether"
  becomes "Consider…"; an open-ended ask becomes "Propose…, share the proposal before changing it". Nothing is
  added that nobody asked for.
- **The ask stays as narrow as the complaint.** Two rows that are one item but weren't paired: pair and compare
  them, not "they should match" (their fields may really differ).
- **Images are resolved.** Colours and highlights become the exact element. Labels from screenshots of our
  own UI are said to be shown there.
- **Later messages win.** An item a change fixed is dropped. A problem that went away with no change is kept:
  why the same input gives different results. After a change, the brief says what changed (not "regression")
  and ends with "Keep working: …".

## Models

Any OpenAI-compatible `/chat/completions` endpoint. Providers live in the config: Gemini and DeepSeek (keys
from `GEMINI_API_KEY` / `DEEPSEEK_API_KEY`), and local llama.cpp servers. Image support is auto-detected from the
server's `/v1/models`; `--images` / `--text` override it. Local presets send `{"temperature": 0.3}`. Mail and
chats can be private: prefer a local model when that matters. A reply with reasoning but no answer is an error.

```bash
reqbuddy models -p gemini        # models, and whether each takes images
reqbuddy config                  # the config (keys hidden); `config path`, `config init`
```

The config is `~/.config/reqbuddy/config.json` (or `$REQBUDDY_CONFIG`), mode 600 because it may hold a key. It
has providers, the default provider, people (name, role, aliases, which one is you), `max_images`,
`image_side` and `cases_url`. On first run it imports the retired macOS app's settings, Keychain key included.

## Cases: actual results from our system

With the internal cases API (`cases_url`, default `http://127.0.0.1:8110`), a brief can include what our own
pipeline returns:

```bash
reqbuddy cases list                                  # recorded cases, live or not, and file slots per demo
reqbuddy cases run pdf_match/issues --strict          # report JSON to stdout; exit 1 unless passed
reqbuddy cases demo pdf_match quote.pdf po.pdf        # our pipeline on our own files (A quotation, B PO)
reqbuddy chat.pdf --demo-run pdf_match --demo-file quote.pdf --demo-file po.pdf
```

Files go up as base64, because the API runs on another machine. A run that fails on its inputs (missing slot,
wrong order, wrong type) stops with "inputs incomplete" and never reaches the brief. When reports are included
and no `--provider` is given, the local provider is used: reports come from customer documents.

## Benchmark

```bash
python3 bench/run_bench.py -n 2 -c "gem=Gemini" -c "35b=local 35|extra={\"temperature\":0.3}"
python3 bench/run_bench.py --rescore ../requirement_example/bench/results/<dir>
```

Cases are private (real mail and chats), so they live outside the repo, in the git-ignored
`../requirement_example/bench/` (or `$REQBUDDY_BENCH`): one JSON per case with inputs, notes, a reference brief
and regex checks, scored locally. Config syntax: `NAME=provider[|model][|key=value…]`, with keys `system`,
`extra`, `image_side` and `mode` (`images` or `text`).

## Code

`extract.py` (inputs → `Source`), `prompt.py` (system prompt + user message), `llm.py` (streaming client),
`cases.py` (cases API), `config.py`, `cli.py`. Run the tests with `uv run pytest`; they use synthetic
fixtures only.

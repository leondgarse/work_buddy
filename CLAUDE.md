# work_buddy

Two tools in one repo:

- **`wb`** (Python, `src/`, `tests/`, `hermes/`): pulls email, git, meetings and Lark into one cited dossier per
  requirement. See `README.md`.
- **reqbuddy** (`reqbuddy/`, its own Python project): a command-line tool that turns emails, Lark chat exports and
  screenshots into a short task prompt for a coding agent (Claude Code, Antigravity CLI), optionally with actual
  results from the internal cases API. See `reqbuddy/README.md`. It replaced a macOS app (removed; it's in git
  history), and it's meant to become a web tool in the case-demos `toolbox/` later. So keep the pipeline in
  plain functions (`extract` → `prompt.build` → `llm.Client.complete`) with no CLI-only logic, and keep it Linux-safe:
  no macOS-only APIs outside optional helpers.

## Rules

- **The GitHub repo is public.** Never commit colleague or customer names, emails, internal hostnames, API keys,
  customer document names or PO numbers, or anything from `requirement_example/`. That folder holds real customer
  mail and chats plus the private benchmark cases, and it's git-ignored. Grep the diff before every commit.
- Commit and push finished, tested work straight to `main`; no need to ask.
- The reqbuddy config is `~/.config/reqbuddy/config.json` (real People list, providers, maybe a key; mode 600).
  Code defaults use placeholders. `Config.from_dict` must keep reading older files: fill new fields with defaults.

## Build and test

```bash
cd reqbuddy
uv run pytest                                   # synthetic fixtures only
uv run reqbuddy brief --dry-run FILE...         # the extracted text and prompt, no model call
uv tool install -e .                            # `reqbuddy` on PATH (editable: picks up code changes)
cd .. && uv run pytest                          # wb tests
```

## Changing the prompt

The prompt is `reqbuddy/src/reqbuddy/system_prompt.txt`. Each rule there came from a real brief that misled
the agent, so check a change against the benchmark, not one run:

```bash
cd reqbuddy; B=../requirement_example/bench
reqbuddy prompt > $B/prompts/vN.txt                       # snapshot a variant
python3 bench/run_bench.py -n 2 -c "gem=Gemini||system=$B/prompts/vN.txt"
python3 bench/run_bench.py --rescore $B/results/<dir>     # after editing a case's checks
```

A case is one JSON file in `requirement_example/bench/`: inputs, optional notes, a reference brief, and regex
checks (run locally, so nothing private goes to a judge). Add a case once its requirement has been implemented,
and turn the implementer's feedback into checks. Base the reference only on what the chat itself shows. Keep
examples in prompt rules generic: never paste a case's own answer into a rule.

## Local models (GPU box)

Gemini is the working model; local ones score lower (see `TODO.md`). When using them:

- The 35B (`Qwen3.6-35B-A3B-Q8_0`) is another project's standalone llama-server, tunneled to `localhost:18010`.
  It sleeps after 10 idle minutes and is often busy, so expect queueing.
- The llama-router is tunneled to `localhost:8080`. **Never request a 35B preset from the router while :18010
  is loaded:** two copies don't fit on the GPUs, and the router has been OOM-killed that way before. Before
  loading any other router model, check free GPU memory, and unload it afterwards
  (`POST /models/unload {"model": …}`).
- Gemma 4 with thinking on never stops reasoning on these inputs: send
  `"chat_template_kwargs": {"enable_thinking": false}` (the client also stops after 200k reasoning characters).
- Local presets use temperature 0.3: it scored higher in the benchmark and ran ~3× faster than the default ~1.0.

# work_buddy

Two tools in one repo:

- **`wb`** (Python, `src/`, `tests/`, `hermes/`): pulls email, git, meetings and Lark into one cited dossier per
  requirement. See `README.md`.
- **ReqBuddy** (`mac_app/`, Swift): a macOS app plus the `reqcli` CLI. It turns emails, Lark chat exports and
  screenshots into a short task prompt for a coding agent (Claude Code, Antigravity CLI). See `mac_app/README.md`.

## Rules

- **The GitHub repo is public.** Never commit colleague or customer names, emails, internal hostnames, API keys,
  or anything from `requirement_example/`. That folder holds real customer mail and chats plus the private
  benchmark cases, and it's git-ignored. Grep the diff before every commit.
- Commit and push finished, tested work straight to `main`; no need to ask.
- Settings live in `~/Library/Application Support/ReqBuddy/settings.json` (the real People list, providers), and
  API keys live in the Keychain. Code defaults use placeholders. `AppSettings` has no migration: adding a stored
  field breaks decoding of the existing file (it falls back to defaults), so write a custom `init(from:)` with
  `decodeIfPresent` first.

## Build and test

```bash
cd mac_app
./scripts/build_app.sh                 # release build, installs ~/Applications/ReqBuddy.app (NO_INSTALL=1 to skip)
swift build --product reqcli           # quick debug CLI: .build/debug/reqcli
.build/debug/reqcli --dry-run FILE...  # show the extracted text and prompt without calling a model
uv run pytest                          # wb tests (repo root)
```

SwiftUI macros need the Xcode toolchain. `build_app.sh` sets `DEVELOPER_DIR` itself; for a bare `swift build` of
the app target, export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Don't rebuild `dist/` while a
benchmark runs: it executes `dist/reqcli`.

## Changing the prompt

The prompt is `PromptBuilder.defaultSystemPrompt`. Each rule there came from a real brief that misled the agent,
so check a change against the benchmark, not one run:

```bash
B=../requirement_example/bench
.build/debug/reqcli --print-system > $B/prompts/vN.txt     # snapshot a variant
python3 bench/run_bench.py -n 2 -c "gem=Gemini||system=$B/prompts/vN.txt"
python3 bench/run_bench.py --rescore $B/results/<dir>      # after editing a case's checks
```

A case is one JSON file in `requirement_example/bench/`: inputs, optional notes, a reference brief, and regex
checks (run locally, so nothing private goes to a judge). Add a case once its requirement has been implemented,
and turn the implementer's critique of the brief into checks. Keep examples in prompt rules generic: never paste
a case's own answer into a rule.

## Local models (GPU box)

- The 35B (`Qwen3.6-35B-A3B-Q8_0`) is another project's standalone llama-server, tunneled to `localhost:18010`
  (Bearer key in the Keychain, preset "MICL Qwen3.6 :18010"). It sleeps after 10 idle minutes and is often busy,
  so expect queueing.
- The llama-router is tunneled to `localhost:8080`. **Never request a 35B preset from the router while :18010
  is loaded:** two copies don't fit on the GPUs, and the router has been OOM-killed that way before. Before
  loading any other router model, check free GPU memory, and unload it afterwards
  (`POST /models/unload {"model": …}`).
- Local presets use temperature 0.3: it scored higher in the benchmark and ran ~3× faster than the default ~1.0.

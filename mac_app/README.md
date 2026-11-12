# ReqBuddy (macOS)

Drop emails and chat exports in; get a short task prompt to paste into a coding agent such as
Claude Code or Antigravity CLI.

- **Inputs:** Mail "Save As… Rich Text Format with attachments" (`.rtfd`), `.eml`, Lark chat PDF
  exports, other PDFs, screenshots, `.txt/.md/.rtf/.docx/.html`, or whole folders. Drop them on the
  window, paste paths, or use ⌘O. Lark chat PDFs are recognised as chats; emails and chats are
  shown to the model without their file names, as descriptions of the request, never as test inputs.
- **Paste screenshots:** ⌘V (or the Paste button) adds an image or Finder-copied files from the
  clipboard. Images are saved as PNG under `~/Library/Application Support/ReqBuddy/Pasted/` so the
  brief can list a real path. Plain text still pastes into the focused field.
- **One requirement per run:** tick the files that belong together and press Generate (⌘↩). Each run
  opens the brief in a new tab, and each file shows which brief(s) it went into. To do the next
  requirement, change the ticks and generate again.
- **Images:** a vision model gets the screenshots / PDF page renders directly, which is needed when a
  message says "the green part". Otherwise the app sends on-device OCR text (Apple Vision, Chinese +
  English). The model is told the colours are lost, so it says so instead of guessing.
  Quoted replies that repeat the same attachments are de-duplicated.
- **Models:** any OpenAI-compatible `/chat/completions` endpoint. Preset providers:
  - A local llama.cpp server (`http://localhost:18010/v1`, `Qwen3.6-35B-A3B-Q8_0`, takes images)
  - A local llama-router (`http://localhost:8080/v1`) for other models. Don't ask it for a model
    that another server already holds, or the GPU box loads two copies.

  Local presets send `{"temperature": 0.3}` (Settings → Models → Extra request JSON). A reply with
  reasoning but no answer is reported as an error. For private mail and chats, prefer a local model.
  - Gemini, using `GEMINI_API_KEY`
  - DeepSeek, using `DEEPSEEK_API_KEY`

  "Images: Auto-detect" asks the server's `/v1/models` whether the model takes images.
- **API keys:** stored in the Keychain, or read from an env var. Apps started from Finder don't see
  `~/.zshrc`, so the env var is read from your login shell.
- **People:** set each person's role (e.g. who is the CTO, who is the customer, which one is you) so the model
  knows whose words are decisions and who the brief is for.
- **Output:** a short prompt with Title, Context, Requirements (bug: **Location** + **Issue** with
  the values seen; change: one direct sentence), and Source files (only real test inputs such as a
  customer PDF, marked `[Should be provided]` when missing). The agent reads the code itself, so
  there are no causes, implementation advice, acceptance criteria or people's names. The prompt rules,
  each from a brief that misled the agent:
  - What was seen is a fact. A guess about why (in chat or in a screenshot) is at most
    "Possible cause (unverified)". A claim nobody can check in the images is written as reported.
  - The asker's certainty is kept: a manager's polite question is an instruction, and "look into
    whether" becomes "Consider…". An open-ended ask becomes "Propose…, share the proposal before
    changing it". Nothing is added that nobody asked for.
  - Colours and highlights are resolved to the exact element. Labels from screenshots of our own UI
    are said to be shown there.
  - Later messages win. Items reported fixed are dropped. When new problems followed a change, the
    brief says what changed (not "regression") and ends with "Keep working: …".
- **My notes** override the sources: items the notes call by design, already handled, or not
  needed are dropped.

## Build

```bash
./scripts/build_app.sh          # → dist/ReqBuddy.app + dist/reqcli, installed to ~/Applications
```

Then start it from Spotlight (⌘Space → ReqBuddy) or Launchpad. Each build replaces the installed
copy and restarts the app if it was running. `NO_INSTALL=1` skips installing, and
`INSTALL_DIR=/Applications` installs there instead. It installs a real copy rather than a
symlink, because Spotlight and Launchpad don't list symlinked apps.

Needs Xcode. The script points `DEVELOPER_DIR` at `/Applications/Xcode.app`, because the Command
Line Tools lack SwiftUI's macro plugins.

## CLI

It uses the same pipeline and settings file (`~/Library/Application Support/ReqBuddy/settings.json`):

```bash
dist/reqcli --provider gemini ../requirement_example/*.pdf    # all files given = one requirement
dist/reqcli --provider deepseek --ocr --dry-run some.rtfd   # print the prompt only
dist/reqcli --provider micl --model unsloth/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M --images chat.pdf
dist/reqcli --print-system                                    # the built-in prompt
dist/reqcli --system v2.txt --extra '{"temperature":0.3}' --image-side 2400 chat.pdf   # A/B knobs
```

## Benchmark

`bench/run_bench.py` runs `reqcli` over cases × model configs and scores each brief with the case's
regex checks, locally. Cases contain private mail and chats, so they live in the git-ignored
`../requirement_example/bench/` (one JSON per case: inputs, notes, reference brief, checks).

```bash
B=../requirement_example/bench
python3 bench/run_bench.py -n 2 -c "gem=Gemini" -c "35b=MICL Qwen3.6 :18010||system=$B/prompts/v4.txt"
python3 bench/run_bench.py --rescore $B/results/<dir>      # re-score saved briefs after editing checks
```

Config syntax: `NAME=provider[|model][|key=value…]` with keys `system`, `extra`, `image_side`, `mode`.

## Layout

- `Sources/ReqCore`: extraction (`Extractors.swift`), prompt (`PromptBuilder.swift`), OpenAI-compatible
  streaming client (`LLMClient.swift`), settings and keys (`Settings.swift`)
- `Sources/ReqBuddy`: SwiftUI app
- `Sources/reqcli`: CLI
- `bench/`: benchmark harness (cases are private, see above)
- `Resources/AppIcon.png`: app icon source (the build makes the `.icns`)

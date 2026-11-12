# ReqBuddy (macOS)

Drop emails and chat exports in; get a requirements brief to paste into Claude Code or another
coding agent.

- **Inputs:** Mail "Save As… Rich Text Format with attachments" (`.rtfd`), `.eml`, Lark chat PDF
  exports, other PDFs, screenshots, `.txt/.md/.rtf/.docx/.html`, or whole folders. Drop them on the
  window, paste paths, or use ⌘O.
- **Paste screenshots:** ⌘V (or the Paste button) adds an image or Finder-copied files from the
  clipboard. Images are saved as PNG under `~/Library/Application Support/ReqBuddy/Pasted/` so the
  brief can list a real path. Plain text still pastes into the focused field.
- **One requirement per run:** tick the files that belong together and press Generate (⌘↩). Each run
  opens the brief in a new tab, and each file shows which brief(s) it went into. To do the next
  requirement, change the ticks and generate again.
- **Images:** a vision model gets the screenshots / PDF page renders directly, which is needed when a
  message says "the green part". Otherwise the app sends on-device OCR text (Apple Vision, Chinese +
  English). The model is told the colours are lost, so it raises an open question instead of guessing.
  Quoted replies that repeat the same attachments are de-duplicated.
- **Models:** any OpenAI-compatible `/chat/completions` endpoint. Preset providers:
  - A local llama.cpp server (`http://localhost:18010/v1`, `Qwen3.6-35B-A3B-Q8_0`, takes images)
  - A local llama-router (`http://localhost:8080/v1`) for other models. Don't ask it for a model
    that another server already holds, or the GPU box loads two copies.
  - Gemini, using `GEMINI_API_KEY`
  - DeepSeek, using `DEEPSEEK_API_KEY`

  "Images: Auto-detect" asks the server's `/v1/models` whether the model takes images.
- **API keys:** stored in the Keychain, or read from an env var. Apps started from Finder don't see
  `~/.zshrc`, so the env var is read from your login shell.
- **People:** set each person's role (e.g. who is the CTO, who is the customer, which one is you) so the model
  knows whose words are decisions and who the brief is for.
- **Output:** a short prompt for the coding agent with Title, Context, Requirements (bug:
  Location + Issue with observed values; change: one direct sentence), and Source files (only real
  test inputs such as a customer PDF, marked `[Should be provided]` if missing). It has no
  explanations or implementation advice, since the agent reads the code itself, and no names.
  Screenshots aren't listed as files.
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
```

## Layout

- `Sources/ReqCore`: extraction (`Extractors.swift`), prompt (`PromptBuilder.swift`), OpenAI-compatible
  streaming client (`LLMClient.swift`), settings and keys (`Settings.swift`)
- `Sources/ReqBuddy`: SwiftUI app
- `Sources/reqcli`: CLI

# TODO

## reqbuddy as a web tool

Done (17 Nov 2026): the **Brief writer**, leondgarse's own tool on the case-demos Tools page, `toolbox/users/leondgarse/reqbuddy/` (its `README.md`). Its
server imports `reqbuddy` from this folder and runs in its `.venv`, so a change to the pipeline here reaches the site
when that server restarts. It calls `extract`, `prompt.build`, `llm.Client`, `CasesAPI` and `DEMO_INPUTS`: keep
those signatures, or change the server with them.

- Not yet used on a real requirement there; the People list starts empty per account.
- Mail `.rtfd` is a folder and cannot be uploaded from a browser: `.eml` or PDF there.

## reqbuddy: cases

The cases API (`http://127.0.0.1:8110`, `~/workspace/case-demos/CASES_API.md`) works from the CLI: `reqbuddy cases
list|health|run|demo`, and `reqbuddy brief --case DEMO/ID` / `--demo-run DEMO --demo-file …` to add actual
results to a brief.

- The customer-PO verification flow is the `pdf_match` demo: **A** is our quotation, **B** is the customer's PO.
  The API runs on the GPU box, so local files go up as base64.
- **Reading a result:**
  - A failure is often missing or wrong inputs (empty slot, A and B swapped, a missing cited quotation), and
    is reported as "inputs incomplete".
  - Recorded cases with deliberate differences (`pdf_match/issues`, `packing/mismatch`) are judged against
    their recording.
  - A custom upload has no recording, so a passed run doesn't mean the documents match.
- Replace the per-demo input table (`cases.DEMO_INPUTS`) once the API can describe its own inputs.
- Retail custom inputs (video plus questions) are not supported yet.

## reqbuddy: prompt and benchmark

- **Benchmark cases:** 5 scored cases (a UI-copy chat and four PO-parsing chats; private, in
  `requirement_example/bench/`). Gemini with prompt v6 (unpaired rows: pair and compare, don't promise a match):
  ~95%, the same as v5 on the old cases, and it fixes the new one. Remaining misses are run-to-run noise (e.g. a
  misread date inside a quoted cause, which v5 does as often).
  Add a case for each new requirement once it's implemented and the implementer has reviewed the brief.
- **Local models (19 Nov 2026, prompt v6, 5 cases).** Seconds are wall time per brief on the 2× RTX 8000 box,
  the first brief after a load included; n = runs per case.

  | model | score | mean s | range s | n |
  |---|---|---|---|---|
  | Gemini 3.8 Flash (cloud, for reference) | ~95% | ~25 | 15–40 | 2 |
  | Qwen3.8-27B dense Q8_0, temp 0.3 | 85% | ~780 | 470–1190 | 1 |
  | Qwen3.6-27B Fable Q4, temp 0.3 | 81% | ~110 | 27–290 | 2 |
  | Muse Glimmer-30B Q4 + dflash drafter (new llama.cpp, standalone) | 80% | ~106 | 74–150 | 1 |
  | Muse Glimmer-30B, "Reasoning effort: high" | 78% | ~100 | 83–139 | 1 |
  | Qwen3.6-35B-A3B Q8, temp 0.3 | 74% | ~100 | 33–350 | 2 |
  | Fable + `--review` second pass | 64% (one run stuck reasoning) | ~520 | 103–1640 | 1 |
  | Nemotron-3.5-30B text-only + Qwen3-VL-4B transcripts | 64% | ~210 | 153–340 | 1 |
  | Gemma-4-26B-A4B, thinking off (on: never answers) | 58% | 8 | 5–11 | 1 |

  All of them read the screenshots fine; they miss the judgement rules (which messages count, guesses vs facts,
  which rows are one item). More reasoning didn't help: Glimmer high effort and the second pass scored lower.
  For private material use the Fable (or Glimmer, same quality and speed); Qwen3.8 is the most accurate local
  model but too slow for daily use. Glimmer files are in `~/workspace/models/Muse-Glimmer-30B-GGUF/` on the box;
  it needs the new llama.cpp in `~/.local/bin`, not the router's build. Re-test when a stronger mid-size model
  lands.
- **No OCR fallback in the CLI** (the macOS app had Apple Vision). Every model in use takes images. If a text-only
  model is needed, call an OCR server on the GPU box rather than adding a platform-specific dependency.
- **Failed-match items:** should they name both sides, the value from the document and the system record it
  should match? The implementer found that useful, but the "don't over-specify" rule drops it. Decide, then add
  a check for it.
- **Keep a guess attached to the message it answers.** It's a benchmark check now; watch it as more cases arrive
  before adding a rule.

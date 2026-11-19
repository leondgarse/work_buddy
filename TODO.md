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
- **Local models (19 Nov 2026, prompt v6, 5 cases, temperature 0.3; Gemini ~95%):** 27B Fable 81% (n=2,
  ~110 s/brief), 35B-A3B 74% (n=2, ~100 s), Nemotron-3.5-30B text-only + Qwen3-VL-4B transcripts 64% (n=1,
  ~210 s), Gemma-4-26B with thinking off 58% (n=1, 8 s; with thinking on it never answers). All of them read the
  screenshots fine; they miss the judgement rules: which messages count (test env vs production), guesses kept
  apart from facts, which two rows are one item. Fable is the local choice for private material; Gemini stays the
  default. Next to try for an all-local setup: the 35B/Fable with thinking budgets, or a two-pass brief (draft,
  then check it against the rules).
- **No OCR fallback in the CLI** (the macOS app had Apple Vision). Every model in use takes images. If a text-only
  model is needed, call an OCR server on the GPU box rather than adding a platform-specific dependency.
- **Failed-match items:** should they name both sides, the value from the document and the system record it
  should match? The implementer found that useful, but the "don't over-specify" rule drops it. Decide, then add
  a check for it.
- **Keep a guess attached to the message it answers.** It's a benchmark check now; watch it as more cases arrive
  before adding a rule.

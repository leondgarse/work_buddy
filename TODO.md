# TODO

## ReqBuddy: run cases through our own system

**Implemented:** settings migration, CasesAPI client, app panel and named upload slots, report sources,
explicit run/review/confirmation, intermediate events, CLI options, and benchmark inputs.
ReqBuddy can now add actual results from our system to a brief. Usage: `mac_app/README.md`.

**Current workflow:**

1. **Add the reported issue** is at the top: upload and select related email/chat files and add notes.
2. **Related case** follows it: one row of six choices — PO check (`pdf_match`), Packing, RFQ, Office,
   Email, and No case. Only one can be selected. Its upload and review interface expands below the row.
3. Upload the case's inputs and click **Run case**. Review Result, Stages, or Full report; replace files
   and rerun as needed. Testing calls the Cases API without calling the brief-writing model.
4. Confirm **Reviewed — use this result in the brief**, then **Generate brief**. Generation uses that
   confirmed report without rerunning the API. No case skips testing and uses the selected issue sources.

**Remaining case work:**

- Replace the per-demo input table when the API can describe its own inputs.
- Support retail custom video/question inputs; recorded retail cases are available through the CLI.

**Verified:** 15 automated tests, live PDF upload/review/rerun with intermediate events, live packing
intermediate events, and the release app build. Latest layout changes also passed a release build.

**What exists:** the demo repo runs a local cases API on `http://127.0.0.1:8110`. It only binds to localhost;
the doc is `~/workspace/case-demos/CASES_API.md`. Endpoints used here:

| Endpoint | Use |
|---|---|
| `GET /api/health` | which demo backends are live, and which runs are busy |
| `GET /api/cases[?demo=…]` | recorded cases: `demo`, `id`, `title`, `live` |
| `POST /api/cases/<demo>/<id>/run?wait=0[&strict=1][&events=1]` | run a recorded case: `202` plus `Location: /api/runs/<run>`; poll until `passed`, `failed` or `error` |
| `POST /api/demos/<demo>/run?wait=0[&events=1]` | run our pipeline on our own files: `{"files": [{"name": …, "base64": …}]}` or `{"path": …}` (per-demo rules, e.g. `pdf_match` takes exactly 2 files, `packing` 1–8) |
| `GET /api/runs/<run>[?events=1]` | the report: `status`, `summary` (`failing`, `differences`, `compare`), `diff` against the recording, `problems`, `server_log` |

**The customer-PO verification flow is the `pdf_match` demo.**

- It takes 2 PDFs: **A** is the reference (the quotation we sent) and **B** is checked against it (the
  customer's PO).
- Recorded cases: `agree` (everything matches after unit conversion) and `issues` (a scanned PO with six
  deliberate differences).
- The API and its files run on the GPU box (case inputs are server paths, tunneled to this Mac), so a file
  from the Mac must be **uploaded as base64 with a name**; the suffix picks the reader. A Mac path won't work.

**Implemented design:**

1. **`CasesAPI` client in `ReqCore`.**
   - Covers health, listing cases, a recorded run, a custom run, and polling. Always uses `wait=0` and polls,
     since runs can be slow, and polling can be cancelled.
   - Base URL is a setting, default `http://127.0.0.1:8110`. The `AppSettings` migration uses
     `decodeIfPresent` to preserve existing providers, People and customized prompts.
2. **"Cases" selector after Add the reported issue.**
   - One row of six choices: five workflows plus No case. Only one case can be selected.
     The selected case alone expands its uploads and output, with health from `/api/health`.
   - Selecting a case opens its upload slots. Testing is a separate action from generating the brief.
   - **Run case** uploads the customer's inputs, polls the API, and shows the output for review. The user
     can replace files and rerun until the output is ready.
   - The user confirms **Reviewed — use this result in the brief**. Generate uses only the confirmed
     report and never reruns the API. Without a selected case, generation uses the email/chat sources alone.
   - Changing files or the events option, rerunning, switching/deselecting the case, or changing the API
     URL revokes confirmation. Incomplete inputs cannot be confirmed. Valid failing results can be
     confirmed as observations of the issue.
   - Include intermediate stages requests `events=1` on POST and polling GETs. Default on for `pdf_match`,
     optional for every other case. The API supports events for all demos; the Stages view exposes each
     returned payload (OCR boxes, text, image paths, checks, matches, answers, etc.) after the run completes.
   - Report sources include status, summary, differences, baseline diff, problems and requested events.
     The prompt treats these as actual observations from our own system and keeps run IDs for traceability.
     Artifact paths in events belong to the server, not the Mac.
3. **File uploads belong to the selected case.**
   - `pdf_match` shows two required slots: "A: our quotation" and "B: customer's PO".
   - Fill a slot by drop, paste, picker, or a test-input file already among the sources.
   - Run is enabled only when required inputs are filled and the backend is live. Uploads send base64
     and filenames to `POST /api/demos/<demo>/run`; a Mac path is never used as a server path.
   - Slots come from a small per-demo table (`packing`: 1–8 documents; `logistics`: 1 RFQ; …) until the
     API can describe its own inputs.
4. **Verify after the fix.**
   - The brief retains the confirmed reports and input order. Re-run those uploaded files after the fix.
   - Custom inputs have no recorded baseline; inspect differences even when execution passes.
   - Strict recorded-case verification remains available through the CLI.
5. **CLI and benchmark.**
   - `reqcli --case <demo>/<id>` (repeatable), or `--demo-run <demo>` with ordered `--demo-file` uploads.
   - `--case-events` includes intermediate events; `--cases-only` prints reports without calling a model.
   - Benchmark cases support recorded cases, custom uploads and `case_events: true`.
6. **Privacy.**
   - Run reports come from customer documents. Send them only to the model the user picked, and default to a
     local model when cases are ticked.

**Reading a run's result:**

- A failure is often **missing or wrong inputs**, not a bug: a slot left empty, A and B swapped, or the
  quotation the PO cites not provided. Treat the API's `bad_input` problems, and an error before the pipeline
  ran, as "inputs incomplete" in the app. Prompt for the missing file; don't add it to the brief as an
  observation.
- Some recorded cases contain deliberate differences (`pdf_match/issues`, `packing/mismatch`, …).
  Compare the run with its recording (`diff`, `matches_recording`) rather than reading `failed`/`passed`
  alone. Custom uploads have no recording; a passed execution does not mean the documents match.

## ReqBuddy: prompt and benchmark backlog

- **Re-run the local benchmark when `:18010` is idle.** The last 35B round queued behind another job. Run
  prompt v4, n=3, the 35B against Gemini, and Fable v4 (only while `:18010` sleeps).
- **Failed-match items:** should they name both sides, the value from the document and the system record it
  should match? The implementer found that useful, but the "don't over-specify" rule drops it. Decide, then add
  a check for it.
- **Keep a guess attached to the message it answers.** One run attached a "two Total Amounts" guess to the
  contract total instead of the quotation import it was about.
- **Add benchmark cases once implemented:** the quotation email (with its notes) and the second PackingList
  chat.
- **Drag messages straight from Mail.app** (file promises) instead of "Save As… .rtfd".

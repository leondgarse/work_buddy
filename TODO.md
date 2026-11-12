# TODO

## ReqBuddy: run cases through our own system

**Implemented:** settings migration, CasesAPI client, app panel and named upload slots, report sources,
explicit run/review/confirmation, CLI options, and benchmark inputs. Usage: `mac_app/README.md`.
Custom uploads rerun without a recorded baseline; retail custom video/question inputs and automatic
API-provided input schemas remain future work. The design below records the intended behavior.

Once a local model writes good enough briefs, ReqBuddy should also get **actual results from our system**,
not just what testers report in screenshots.

**What exists:** the demo repo runs a local cases API on `http://127.0.0.1:8110`. It only binds to localhost;
the doc is `~/workspace/case-demos/CASES_API.md`. Endpoints used here:

| Endpoint | Use |
|---|---|
| `GET /api/health` | which demo backends are live, and which runs are busy |
| `GET /api/cases[?demo=…]` | recorded cases: `demo`, `id`, `title`, `live` |
| `POST /api/cases/<demo>/<id>/run?wait=0[&strict=1]` | run a recorded case: `202` plus `Location: /api/runs/<run>`; poll until `passed`, `failed` or `error` |
| `POST /api/demos/<demo>/run` | run our pipeline on our own files: `{"files": [{"name": …, "base64": …}]}` or `{"path": …}` (per-demo rules, e.g. `pdf_match` takes exactly 2 files, `packing` 1–8) |
| `GET /api/runs/<run>` | the report: `status`, `summary` (`failing`, `differences`, `compare`), `diff` against the recording, `problems`, `server_log` |

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
   - Base URL is a setting, default `http://127.0.0.1:8110`. Add the `AppSettings` migration first (see backlog).
2. **"Cases" selector at the top of the app input pane.
   - Three columns and two rows: five workflows plus No case. Only one case can be selected.
     The selected case alone expands its uploads and output, with health from `/api/health`.
   - Selecting a case opens its upload slots. Testing is a separate action from generating the brief.
   - **Run case** uploads the customer's inputs, polls the API, and shows the output for review. The user
     can replace files and rerun until the output is ready.
   - The user confirms **Reviewed — use this result in the brief**. Generate uses only the confirmed
     report and never reruns the API. Without a selected case, generation uses the email/chat sources alone.
   - Changing files, rerunning, deselecting a case, or changing the API URL revokes confirmation. Incomplete
     inputs cannot be confirmed. Valid failing results can be confirmed as observations of the issue.
   - Include intermediate stages requests `events=1` on POST and polling GETs. Default on for `pdf_match`,
     optional for every other case. The API supports events for all demos; the Stages view exposes each
     returned payload (OCR boxes, text, image paths, checks, matches, answers, etc.) after the run completes.
   - Report sources include status, summary, differences, baseline diff, problems and requested events. The prompt treats
     these as actual observations from our own system and keeps run IDs for traceability.
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
   - `reqcli --case <demo>/<id>` (repeatable) and `--demo-run <demo>`, so benchmark cases can include actual
     results.
6. **Privacy.**
   - Run reports come from customer documents. Send them only to the model the user picked, and default to a
     local model when cases are ticked.

**Reading a run's result:**
- A failure is often **missing or wrong inputs**, not a bug: a slot left empty, A and B swapped, or the
  quotation the PO cites not provided. Treat the API's `bad_input` problems, and an error before the pipeline
  ran, as "inputs incomplete" in the app. Prompt for the missing file; don't add it to the brief as an
  observation.
- Some recorded cases fail on purpose (`pdf_match/issues`, `packing/mismatch`, …). Show each case's blurb next
  to it, and compare the run with its recording (`diff`, `matches_recording`) rather than reading
  `failed`/`passed` alone.

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

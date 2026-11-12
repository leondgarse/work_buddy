# TODO

## ReqBuddy: run cases through our own system

**Implemented:** settings migration, CasesAPI client, app panel and named upload slots, report sources,
strict recorded-case verification, CLI options, and benchmark inputs. Usage: `mac_app/README.md`.
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
2. **"Cases" panel in the app**, under the sources.
   - Cases grouped by demo, from `/api/cases`; a demo that `/api/health` reports as not live is greyed out.
     One checkbox per case.
   - When any case is ticked, Generate runs those cases first, shows each case's status, then adds each
     report as a source: "case run `<demo>/<id>` (actual output of our system)", with status, failing checks
     or differences, the diff against the recording, and problems.
   - New prompt rule: a case report is an observation from our own system, so state it as
     "Actual result (case `<demo>/<id>`): …". It also confirms whether the reported problem reproduces.
3. **File upload when a demo is chosen.**
   - A recorded case isn't enough for most briefs: the files that matter are the customer's own PO and the
     quotation it answers. A brief usually lists them under "Source files" as `[Should be provided]`.
   - So choosing a demo opens **one upload slot per input the demo expects**. For `pdf_match`: "A: our
     quotation" and "B: the customer's PO". Fill a slot by drop, paste or picker, or from a test-input file
     already among the sources.
   - Run is enabled only when every required slot is filled. The files go up as base64 with their names, to
     `POST /api/demos/<demo>/run`.
   - Slots come from a small per-demo table in the app (`pdf_match`: A, B; `packing`: 1–8 documents;
     `logistics`: 1 RFQ; …) until the API can describe its own inputs.
4. **Verify after the fix.**
   - When the agent has implemented the brief, re-run the same cases with `strict=1` and show pass or fail on
     the brief's tab.
   - Keep the run ids in the brief so the result can be traced back.
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

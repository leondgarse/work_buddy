# TODO

## ReqBuddy: run cases through our own system

Once a local model writes good enough briefs, ReqBuddy should also get **actual results from our system**,
not just what testers report in screenshots.

**What exists:** the demo repo runs a local cases API on `http://127.0.0.1:8110`. It only binds to localhost;
the doc is `~/workspace/case-demos/CASES_API.md`. Endpoints used here:

| Endpoint | Use |
|---|---|
| `GET /api/health` | which demo backends are live, and which runs are busy |
| `GET /api/cases[?demo=…]` | recorded cases: `demo`, `id`, `title`, `live` |
| `POST /api/cases/<demo>/<id>/run?wait=0[&strict=1]` | run a recorded case: `202` plus `Location: /api/runs/<run>`; poll until `passed`, `failed` or `error` |
| `POST /api/demos/<demo>/run` | run our pipeline on our own files: `{"files": [{"path": …}]}` (per-demo rules, e.g. `pdf_match` takes exactly 2 files, `packing` 1–8) |
| `GET /api/runs/<run>` | the report: `status`, `summary` (`failing`, `differences`, `compare`), `diff` against the recording, `problems`, `server_log` |

**Plan:**

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
3. **Custom runs for test inputs.**
   - The test-input files among the sources (for example a customer PO PDF plus its quotation PDF) can be sent
     to `POST /api/demos/<demo>/run` by path.
   - Suggest the demo from the file set. Before calling, check the demo's file-count rule.
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

**Open:**
- Is the customer-PO verification flow (the one most briefs are about) exposed as a demo yet, or does it need
  its own runner?
- Some recorded cases are deliberate failures, such as mismatches or unsupported language. Show their expected
  verdict next to each case, so a "failed" there doesn't read as a bug.

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
- **`AppSettings` migration:** a custom `init(from:)` using `decodeIfPresent`, needed before adding any stored
  field (cases base URL, target agent, …). Without it, existing settings fall back to defaults.
- **Drag messages straight from Mail.app** (file promises) instead of "Save As… .rtfd".

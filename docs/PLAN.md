# Ai-Clothing-Recommendation: PLAN v1.1

Scope and acceptance criteria: `docs/SPEC.md`. Architecture: `docs/HLD.md`. This file is the phase-by-phase build checklist — work one phase at a time (CLAUDE.md), tick a box, commit, move on.

**Decisions made while planning (not in SPEC/HLD, recorded here so they aren't re-litigated):**

1. **Label-timing mismatch.** Phase 1's done-when needs classifier spot-check accuracy, but those labels are due Oct 24, two days after Phase 1 ends (Oct 22); Phase 4 has the same pattern (query labels due Oct 28, the same day the phase ends). Every phase with this pattern gets two checkboxes: **pipeline done** (code runs end-to-end on whatever data/labels exist) and **metric reported** (ticks once labels land and `eval/run_all.py --phase N` is rerun).
2. **Women's data and your partner.** Your partner is building the women's fit model independently, on their own laptop, against the **same local Supabase (Docker) instance** on your machine — not a separate crawl, not a snapshot export. Each of you runs your own fit model filtered by department (yours: men+unisex; theirs: women+unisex). Phase 2's chart normalizer therefore runs over **all departments** (it's per-chart, not per-department, so this is free). Phase 0 adds a read-only Postgres role scoped to the catalog tables for their connection. Exposing local Supabase on the LAN and sharing the read-only connection string is **your** manual task, not something the pipeline automates.
3. **No integration hooks for women's fit in this repo.** Phase 3's fit model stays hardcoded to the male ANSUR subset, men+unisex, per SPEC. No department-pluggable abstraction is added speculatively — merging your partner's model later is unplanned future work.
4. **Image-only size charts** auto-abstain in v1 (no vision-LLM call) — stretch goal #6 stays out of scope.
5. **Demo-page JS tests:** a couple of `node:test` unit tests for the pure history-logic functions (cap-at-50, clear, export shape) plus a manual in-browser QA checklist. No Playwright infra for a single static page.
6. **Purchase correction is blended, not an override.** Per dimension, the body estimate is `n/(n+k) * purchase_implied + k/(n+k) * height_weight_estimate`, where n = purchases informing that dimension; height + weight alone at n = 0. k lives in `config/ranking.yaml`, starting 1; Phase 6.6 reports the closet leave-one-out accuracy for k in {0.5, 1, 2} since the closet set is too small to trust a single tuned value.
7. **Check-link and purchase lookups never 4xx on an expected miss.** Not-in-catalog and department-unsupported are both ordinary HTTP 200 responses with a `status` field — consistent with how `/search` already handles `department=women`.
8. **"Fits better" is a margin, not just "higher."** A check-link similar item must beat the linked product's own best-size `fit_probability` by at least a margin (config, starting 0.05), not merely tie or edge it out — avoids surfacing near-identical alternatives as if they were meaningfully better.

---

## Phase 0 — Oct 21: repo scaffold, local Supabase, migrations

**Goal:** stand up the repo skeleton and a working local Supabase so every later phase has somewhere to write code and data.

**Files/modules:**
- `config/` (empty, populated per-phase)
- `pipeline/{crawl,classify,charts,normalize,variants}/__init__.py`
- `models/{body,fit,embed,style}/__init__.py`
- `serving/{api,demo}/__init__.py`
- `eval/{gold,closet,queries,personalization}/`, `eval/run_all.py` (stub)
- `data/{raw,interim}/.gitkeep`, `artifacts/.gitkeep`
- `results/metrics.csv` (header row only: `pillar,method,metric,value,ci_low,ci_high,artifact_version,date`)
- `requirements-offline.txt`, `requirements-serving.txt`
- `pytest.ini` / `conftest.py`
- `.gitignore` additions: `data/`, `artifacts/`, `.venv/`, `__pycache__/`, `eval/personalization/sessions/`

**Supabase migrations:**
- `0001_init.sql` — all core tables (HLD §5): `stores`, `products`, `variants`, `size_charts`, `chart_measurements`, `variant_measurements` (view), `extraction_runs`, `gold_labels`, `closet_items`, `request_log`.
- `0002_partner_readonly_role.sql` — `partner_ro` role, `SELECT` only on `products`, `variants`, `size_charts`, `chart_measurements`, `variant_measurements` (never `closet_items`/`gold_labels`/`extraction_runs` — those stay yours).

**Config files:** none yet.

**Tests / done when:**
- [ ] `supabase start` succeeds; `supabase db reset` applies both migrations cleanly; `pytest -q` runs (smoke test importing every package).
- Command: `supabase start && supabase db reset && pytest -q`

**Manual tasks required (SPEC §13):** confirm GPU + run one 7B model in Ollama; install Docker Desktop (WSL2). Both due Oct 21, both block everything downstream.

**Risks / fallback:** Supabase CLI/Docker networking issues on Windows+WSL2 → disable unused local services in `supabase/config.toml` (`analytics`, `edge_runtime`) to cut container weight if resources are tight.

---

## Phase 1 — Oct 22: store vetting, crawler, category + department classifier

**Goal:** get a crawled, classified catalog (all departments) into local Supabase.

**Files/modules:**
- `pipeline/crawl/{vet_stores.py, crawler.py, rate_limiter.py}`
- `pipeline/classify/{rules.py, llm_classifier.py, run.py}`
- `config/stores.yaml`, `config/classifier_rules.yaml`

**Supabase migrations:** none expected; add `0003_classification_fields.sql` (`classified_by`, `confidence` columns on `products`) only if implementation needs fields beyond HLD's schema.

**Config files:**
- `stores.yaml` — candidate store domains + vetting status/notes (populated as stores are vetted).
- `classifier_rules.yaml` — category keywords by `product_type`/`tags`/`title`; department keywords; unisex default when no men/women signal is found.

**Tests / done when:**
- [ ] **Pipeline done:** `pytest pipeline/crawl pipeline/classify -q` passes (rate limiter enforces 1 req/s, robots.txt respected, rules classifier correct on fixtures); `python -m pipeline.crawl.crawler --snapshot <date>` then `python -m pipeline.classify.run` populate 15–20 stores with every product classified (category + department).
- [ ] **Metric reported:** once the 50-product spot-check labels exist (due Oct 24), `python -m eval.run_all --phase 1` writes classifier accuracy to `results/metrics.csv`.

**Manual tasks (SPEC §13):** shortlist stores (Oct 22 — crawl starts against whatever's shortlisted first); label the 50-product classifier spot check (Oct 24, feeds the metric checkbox above).

**Risks / fallback:** a store blocks crawling or hides its chart behind a third-party app → vetting script flags it, swap the store. Spot-check labels landing after Phase 1's nominal end is expected (decision 1) — tracked, not a blocker.

---

## Phase 2 — Oct 23–25: chart locator, rules parser, LLM extract + review, validators, variant mapper

**Goal:** turn every unique size chart (every department) into validated garment measurements in cm.

**Files/modules:**
- `pipeline/charts/{locator.py, fingerprint.py}`
- `pipeline/normalize/{rules_parser.py, schema_builder.py, llm_extractor.py, llm_reviewer.py, validators.py, ease.py, run.py}`
- `pipeline/variants/mapper.py`
- `pipeline/llm/cache.py` (shared LLM cache — design below)
- `prompts/{chart_extract_v1.md, chart_review_v1.md}`
- `config/dimensions.yaml`, `config/ease.yaml`

**Supabase migrations:** `variant_measurements` view ships in `0001_init.sql`; only split into its own migration (`0004_variant_measurements_view.sql`) if its shape wasn't finalized by Phase 0.

**Config files:**
- `dimensions.yaml` — `tops: [chest, body_length, sleeve, shoulder?]`, `bottoms: [waist, hip, inseam, rise?]` (`?` = include if available, per SPEC §5).
- `ease.yaml` — fixed cm ease per category × dimension for body-basis → garment conversion. Initial values are placeholders, sanity-checked against the closet set in Phase 3 (open item, below).

**Tests / done when:**
- [ ] **Pipeline done:** unit tests for the rules parser (fixture HTML tables), validators (size ordering, plausible ranges, unit conversion, half-measurement doubling), schema builder (schema matches a product's actual size list), and image-only charts auto-abstaining (decision 4). `pytest pipeline/charts pipeline/normalize pipeline/variants -q`.
- [ ] **Metric reported:** once the 50 gold charts are labelled (due Oct 24, inside this phase's window), `python -m eval.run_all --phase 2` writes field precision (target ≥90%) and abstain rate vs the rules-only baseline to `results/metrics.csv`.

**Manual tasks (SPEC §13):** label 50 gold charts (Oct 24).

**Risks / fallback:** LLM throughput too slow for the unique-chart backlog → rules-first + dedup already minimizes calls; if still tight, widen the abstain threshold rather than iterating on prompts into Phase 3. Women's charts add volume but no new code path (decision 2).

---

## Phase 3 — Oct 26: body estimator, fit model

**Goal:** predict body measurements from height/weight and learn per-dimension fit words from your closet set (men's/unisex only — decision 3).

**Files/modules:**
- `models/body/{train_ansur.py, estimator.py, ansur_mapping.py}`
- `models/fit/{ordinal_model.py, thresholds_fallback.py, train.py}`
- `pipeline/import/load_closet.py` (loader only — never generates/fills closet labels, per CLAUDE.md)
- `config/fit_thresholds.yaml`

**Supabase migrations:** none — `closet_items`/`gold_labels` already exist from Phase 0; this phase only reads/writes rows via the loader, run against your own measured data.

**Config files:**
- `fit_thresholds.yaml` — hand-set cm thresholds per dimension type, used as the fallback model.
- ANSUR → dimension-name mapping, either its own `ansur_mapping.yaml` or a section of `dimensions.yaml`.

**Tests / done when:**
- [ ] unit tests for the ANSUR mapping, ordinal model fit on synthetic data, threshold fallback.
- [ ] `python -m eval.run_all --phase 3` writes ANSUR MAE per dimension (vs height-only baseline) and closet leave-one-out accuracy with confidence intervals (vs fixed-threshold baseline) to `results/metrics.csv`.

**Manual tasks (SPEC §13):** measure 20 garments + your body (Oct 25 — one day before this phase, tight; see risks).

**Risks / fallback:** a 20-garment closet set risks overfitting the ordinal model → keep it few-parameter (already a SPEC constraint); if unstable, ship the fixed-threshold fallback as the model actually used in L2, report the ordinal model's number as experimental only.

---

## Phase 4 — Oct 27–28: embeddings, L1 retrieval with filters, L2 ranking

**Goal:** retrieve and rank candidates by relevance + fit, with the query encoder exported to a server-safe (no-PyTorch) format.

**Files/modules:**
- `models/embed/{encode.py, build_index.py, export_onnx.py}` (PyTorch/sentence-transformers allowed here — offline only)
- `ranking/{l1.py, l2.py}` — department-agnostic, onnxruntime + NumPy only, imported by both `eval/` and `serving/api/` so the exact same scoring code is evaluated and served
- `config/ranking.yaml` — `w_rel`, `w_fit` (real values); `w_style: 0` placeholder; signal-weight table placeholder (both finalized in Phase 6.5)

**Supabase migrations:** none — embeddings/index live in the artifact bundle, not the DB (HLD §5).

**Config files:** `ranking.yaml` as above.

**Tests / done when:**
- [ ] **Pipeline done:** FAISS build/query roundtrip test; L1 filter unit tests (category/department/fit-tolerance dropping); L2 scoring unit tests on fixed inputs; BM25 baseline implemented. `pytest ranking models/embed -q`.
- [ ] **Metric reported:** once the 50-query set is labelled (due Oct 28, the same day this phase ends — decision 1 pattern), `python -m eval.run_all --phase 4` writes Recall@50 and NDCG@10 vs BM25 to `results/metrics.csv`.

**Manual tasks (SPEC §13):** write and label the 50-query set (Oct 28).

**Risks / fallback:** labels land the same day metrics are due, no buffer to react to a bad score → start writing queries earlier (even unlabelled, to exercise the pipeline), backfill real relevance labels Oct 28 and rerun the same day. If the timeline slips further, SPEC's own fallback is to cut the query set to 30.

---

## Phase 5 — Oct 29: `run_all` evaluation, artifact bundle

**Goal:** one command regenerates every metric, and one versioned bundle is all the server needs.

**Files/modules:**
- `eval/run_all.py` (orchestrates `eval/phase{1,2,3,4,6_5}_*.py`)
- `models/bundle.py` (packages ONNX encoder, FAISS index + ID map, body/fit models, measurement tables into `artifacts/vN/`)
- `config/version.yaml` (artifact version string)

**Supabase migrations:** none.

**Config files:** `version.yaml`, bumped per bundle.

**Tests / done when:**
- [ ] test that `eval/run_all.py` (no `--phase`) writes all required `(pillar, method, metric, artifact_version)` rows with no gaps; smoke test that instantiates `ranking.l1`/`ranking.l2` against a built `artifacts/vN/` bundle without starting the API.
- [ ] `python -m eval.run_all` regenerates the full `results/metrics.csv` in one command; `artifacts/v1/` contains all expected files.

**Manual tasks:** none new.

**Risks / fallback:** a full `run_all` becomes slow/flaky across pillars → cache intermediate per-pillar outputs so `--phase` reruns are incremental, while the no-argument form still guarantees a full regeneration.

---

## Phase 6 — Oct 30: API, demo page, serving image, deploy

**Goal:** a Docker-tested FastAPI server and a static demo page both return real results.

**Files/modules:**
- `serving/api/{main.py, schemas.py, profile.py, l1.py, l2.py, explain.py, logging.py, health.py}` (`l1.py`/`l2.py` re-export from `ranking/`)
- `serving/demo/{index.html, app.js, history.js, styles.css}`
- `Dockerfile` (onnxruntime + NumPy + FastAPI only — no torch, no LLM client)
- `config/server.yaml` (CORS allowed origin, artifact path)

**Supabase migrations:** none expected (`request_log` already exists); add `0005_request_log_artifact_version.sql` only if `artifact_version` needs its own column.

**Config files:** `server.yaml` as above.

**Tests / done when:**
- [ ] API contract tests via `httpx`/`TestClient`: `/search` happy path, `/health`, `liked` silently truncated to 50, unknown product IDs ignored (no 400 in either case).
- [ ] static test grepping `serving/**/*.py` and `requirements-serving.txt` for `torch`/`transformers`/`ollama`/any LLM SDK, asserting none are present.
- [ ] test asserting the `request_log` insert path only ever touches `(timestamp, step timings, result_count, artifact_version)` columns.
- [ ] **Local:** `docker build -t ai-clothing-api . && docker run ... && curl /health` returns results.
- [ ] **Live:** the deployed Hugging Face Space (fallback Render) also returns results — manual/semi-manual, needs your hosting account; I prepare and locally verify the image, you own the actual deploy action.

**Manual tasks:** none new from SPEC §13, but hosting-account/login steps are yours.

**Risks / fallback:** free-host memory limits with the ONNX encoder + FAISS index in memory, cold start >60s → encoder already planned as int8 ONNX; shrink the index to in-scope categories first if memory is tight; Render is the documented fallback host (SPEC §4).

---

## Phase 6.5 — Oct 31–Nov 1: style personalization

**Goal:** `liked` clicks/ratings shape L2 ranking via a per-request, never-stored style profile, and the demo page supports the full history lifecycle.

**Files/modules:**
- `serving/api/style.py` (style profile builder, fleshed out from the Phase 6 stub)
- `serving/demo/history.js` (store/send/clear/export)
- `serving/demo/history.test.mjs` (`node:test` unit tests, decision 5)
- `eval/personalization/{session_schema.py, metrics.py}`

**Supabase migrations:** none — no server-side storage of shopper data, by design.

**Config files:** `ranking.yaml` updated with real `w_style` and the signal-weight table (SPEC §5): `rated5: +1.0, rated4: +0.5, rated3: 0, rated2: -0.5, rated1: -1.0, click: +0.25` — tuned after the personalization sessions.

**Tests / done when:**
- [ ] unit tests for the style profile builder (weighted average, 3-signal minimum gate, unknown-ID ignore, 50-cap, no double-boost for already-rated items).
- [ ] `node:test` unit tests for `history.js`'s pure functions (cap-at-50, clear, export shape) plus a short manual in-browser QA checklist.
- [ ] once your exported session JSON exists (due Nov 1), `python -m eval.run_all --phase 6.5` writes mean top-5 rating before/after with CI, and click-to-rating agreement, to `results/metrics.csv`, vs the `w_style=0` baseline.

**Manual tasks (SPEC §13):** run the 10 fixed queries + rate top 5 each (before); make 20+ more ratings on other searches; rerun the same 10 queries + rate top 5 (after); export history — all by Nov 1.

**Risks / fallback:** only a 2-day window right after the Phase 6 deploy for a lot of manual interaction → SPEC's own fallback already applies: if it slips, Phase 6.5 moves to stretch without affecting Phases 0–6.

---

## Phase 6.6 — Nov 2–3: portable fit profile (purchases + check a link)

**Goal:** self-reported purchases correct the body estimate (blended with height/weight, never a full override — decision 6) and double as a style signal; a pasted product URL from a catalog store gets sized directly and compared against better-fitting alternatives.

**Files/modules:**
- `serving/api/purchases.py` (parse `purchases`, build the per-dimension blended estimate, map verdicts to style-signal weights)
- `serving/api/check_link.py` (URL → domain + handle resolution, `not_in_catalog`/`department_unsupported` responses, similar-items selection)
- `models/fit/invert.py` (pure function: garment measurement + ease + fit word → implied body measurement; the inverse of the existing fit-word thresholds; shared by `purchases.py` and `eval/phase6_6_purchases.py`)
- Modify `serving/api/profile.py` (blend purchase-implied measurements into the height/weight estimate, C12a)
- Modify `serving/api/style.py` (fold purchase verdicts into the existing style-profile weighted sum, C12f)
- Modify `serving/api/schemas.py` (`Purchase`, `CheckLinkRequest`, `CheckLinkResponse` models)
- Modify `serving/api/main.py` (register `POST /check-link`)
- Modify `serving/api/logging.py` (add `endpoint` to the `request_log` insert)
- `serving/demo/purchases.js` (add/remove/list purchases, capped at 30, local-storage backed)
- `serving/demo/checklink.js` (URL box, renders the `/check-link` response or its `status` message)
- `eval/phase6_6_purchases.py` (closet leave-one-out, k in {0.5, 1, 2})
- `eval/phase6_6_checklink.py` (the four endpoint test cases + latency)

**Supabase migrations:**
- `0006_request_log_endpoint.sql` — add a nullable `endpoint` column to `request_log` (still timings/result-count only, never a URL or query).

**Config files:**
- `config/ranking.yaml` additions: `purchase_correction_k` (starting 1), `check_link_fit_margin` (starting 0.05), purchase verdict → style-signal weights (`wear: 1.0, wear_but_flawed: 0.0, dont_wear: -1.0`).

**Tests / done when:**
- [ ] unit tests for `models/fit/invert.py` (a garment measurement + fit word round-trips to the same fit word when re-scored by the existing fit model).
- [ ] unit tests for the blend (n=0 falls back to height/weight exactly; n=1 is a 50/50 average at k=1; n=2 is 2:1; unknown purchase product IDs are ignored and don't count toward n).
- [ ] unit tests for the style-signal mapping (wear/wear_but_flawed/dont_wear weights; purchases and `liked` combine toward the same 3-signal minimum).
- [ ] unit tests for the URL resolver's four cases: crawled product URL (match), unknown store, unknown product on a known store, known product in an unsupported department — all HTTP 200.
- [ ] unit test asserting `check_link.py`'s similar-items filter requires `fit_probability >= linked_fit_probability + margin` and excludes the linked product itself.
- [ ] **Metric reported:** `python -m eval.run_all --phase 6.6` writes, to `results/metrics.csv`: per-dimension purchases-blended-vs-height/weight-only leave-one-out accuracy with confidence intervals for k in {0.5, 1, 2} (noting the closet set is small), and check-link end-to-end latency (p50/p95) from `request_log`.

**Manual tasks (SPEC §13):** enter my own purchases on the demo page (Nov 2–3) — informal QA; the leave-one-out metric reuses the existing closet labels, no new labelling.

**Risks / fallback:** a 2-day window right after Phase 6.5's own tight window → SPEC's fallback order applies: cut the query set to 30 first, then move Phase 6.6 to stretch, then Phase 6.5, with Phases 0–6 unaffected.

---

## Phase 7 — Nov 4: README, buffer

**Goal:** publish the results and architecture; buffer for overflow.

**Files/modules:** `README.md` (results table generated from `results/metrics.csv`, architecture diagram, setup instructions); final pass on this file's checkboxes.

**Supabase migrations:** none.

**Config files:** none new.

**Tests / done when:**
- [ ] `python -m eval.render_readme_table --check` verifies every number in the README's results table matches `results/metrics.csv` exactly (no hand-typed numbers).
- [ ] results table and diagram published.

**Manual tasks (SPEC §13):** check git history for secrets before making the repo public.

**Risks / fallback:** this day is the buffer — absorbs slippage from earlier phases.

---

## Cross-cutting: dependencies (pinned)

**Offline** (`requirements-offline.txt` — pipeline, models, eval; PyTorch and the Ollama client live only here):

```
polars==1.9.0
pyarrow==17.0.0
httpx==0.27.2
tenacity==9.0.0
lxml==5.3.0
beautifulsoup4==4.12.3
pyyaml==6.0.2
pydantic==2.9.2
ollama==0.3.3
torch==2.5.1
transformers==4.46.0
sentence-transformers==3.2.1
optimum[onnxruntime]==1.23.3
scikit-learn==1.5.2
statsmodels==0.14.4
faiss-cpu==1.9.0
numpy==2.1.3
matplotlib==3.9.2
psycopg[binary]==3.2.3
python-dotenv==1.0.1
pytest==8.3.3
```

**Serving** (`requirements-serving.txt` — API only; enforced by the Phase 6 static-import test — no PyTorch, no LLM):

```
fastapi==0.115.4
uvicorn[standard]==0.32.0
pydantic==2.9.2
onnxruntime==1.19.2
numpy==2.1.3
faiss-cpu==1.9.0
psycopg[binary]==3.2.3
python-dotenv==1.0.1
```

## Cross-cutting: LLM JSON schemas

**Extraction schema**, built per-product by `pipeline/normalize/schema_builder.py:build_extraction_schema(category, size_labels, dimensions_cfg)` from `config/dimensions.yaml` (which dimensions are required for tops vs bottoms) and that product's deduped, ordered variant size labels — every listed size must get a row:

```json
{
  "type": "object",
  "required": ["basis", "sizes"],
  "properties": {
    "basis": {"type": "string", "enum": ["garment", "body"]},
    "sizes": {
      "type": "array",
      "minItems": "<N = len(size_labels)>",
      "maxItems": "<N>",
      "items": {
        "type": "object",
        "required": ["size_label", "<...dims for this category>"],
        "properties": {
          "size_label": {"type": "string", "enum": "<ordered size_labels>"},
          "chest_cm": {"type": ["number", "null"]},
          "body_length_cm": {"type": ["number", "null"]},
          "sleeve_cm": {"type": ["number", "null"]},
          "shoulder_cm": {"type": ["number", "null"]},
          "waist_cm": {"type": ["number", "null"]},
          "hip_cm": {"type": ["number", "null"]},
          "inseam_cm": {"type": ["number", "null"]},
          "rise_cm": {"type": ["number", "null"]}
        }
      }
    },
    "notes": {"type": ["string", "null"]}
  }
}
```

**Review schema** (second LLM pass):

```json
{
  "type": "object",
  "required": ["overall_confidence", "issues"],
  "properties": {
    "overall_confidence": {"type": "string", "enum": ["high", "medium", "low"]},
    "issues": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["size_label", "dimension", "problem", "severity"],
        "properties": {
          "size_label": {"type": "string"},
          "dimension": {"type": "string"},
          "problem": {"type": "string", "enum": ["implausible_value", "wrong_unit", "half_measurement_suspected", "basis_mismatch", "size_order_violation", "other"]},
          "severity": {"type": "string", "enum": ["low", "medium", "high"]},
          "suggested_value_cm": {"type": ["number", "null"]}
        }
      }
    }
  }
}
```

## Cross-cutting: LLM cache design

- **Key:** `sha256(f"{model}:{prompt_version}:{sha256(json.dumps(input_payload, sort_keys=True))}")`.
- **Storage:** `data/interim/llm_cache/<model>/<prompt_version>/<hash[:2]>/<hash>.json` (under `data/`, gitignored), containing `{model, prompt_version, input_hash, prompt_text, raw_response, parsed_json, latency_ms, created_at}`.
- **Lookup order:** check the disk file by key first; on hit, return the parsed result with no Ollama call and no DB write. On miss, call Ollama, write the disk file, and insert one row into `extraction_runs` (local Supabase only) for audit.
- **Invalidation:** bump the `prompt_version` string in the relevant `prompts/*.md` file whenever the template changes (e.g. `v1` → `v2`). The new version writes to a new directory, so old entries simply stop being reachable — no deletion needed. A `pipeline/llm/cache.py:purge(model=None, prompt_version=None)` utility and a `--no-cache` CLI flag exist for manual cleanup/debugging.

## Cross-cutting: `liked` field and demo-page history

**API:** `LikedItem{product_id: str, signal: Literal["click","rating"], value: int|None}` (`value` required and 1–5 only when `signal=="rating"`). `liked: list[LikedItem]` is silently truncated to the most recent 50 server-side (no 422 on >50 — defensive, since the demo already caps client-side). Unknown `product_id`s (not in the artifact's ID map) are skipped when building the style profile, never raise an error. The style profile only builds once at least 3 valid signals remain after filtering. `height_cm`, `weight_kg`, `query`, and `liked` are never written to `request_log` or disk anywhere in `serving/` — enforced by the Phase 6 test asserting the log-insert code path's column list.

**Demo page:** `localStorage["acr_history_v1"] = {clicks: [{product_id, ts}], ratings: [{product_id, value, ts}]}`. On each search, the most-recent 50 entries (clicks + ratings combined, sorted by `ts` desc) are mapped into the `liked` request shape. "Clear my history" wipes the key. "Export my history" downloads the **full** stored history (not just the capped 50) as `acr_history_<timestamp>.json`; this exact shape is what `eval/personalization/session_schema.py` parses for the Phase 6.5 metrics, so the two are defined together.

## Cross-cutting: `purchases` field and the portable fit profile

**API:** `Purchase{product_id: str, size: str, fit: dict[str, Literal[five fit words]], verdict: Literal["wear","wear_but_flawed","dont_wear"]}` (`fit`'s keys are whichever dimensions apply to that product's category, SPEC §5's five-word scale). `purchases: list[Purchase]` is silently truncated to the most recent 30 server-side, mirroring `liked`'s cap pattern (no 422 on >30). A purchase whose `product_id` isn't in the artifact's ID map, or whose product is in an unsupported department, is dropped before either the blend or the style profile sees it — never an error. `purchases` is never written to `request_log` or disk anywhere in `serving/`, same enforcement as `liked`.

**Blend (decision 6):** for each dimension, `models/fit/invert.py` turns each surviving purchase's `(garment_cm, ease, fit_word)` into an implied body measurement; if n purchases inform a dimension, the estimate is `n/(n+k) * mean(implied) + k/(n+k) * height_weight_estimate`, k from `config/ranking.yaml`. n=0 → height/weight unchanged.

**Style signal:** each surviving purchase's `verdict` is weighted (`wear: +1.0, wear_but_flawed: 0, dont_wear: -1.0`, same config) and folded into the same weighted-embedding-average style profile as `liked`'s signals, sharing the 3-signal minimum gate.

**Demo page:** `localStorage["acr_purchases_v1"] = [{product_id, size, fit, verdict, ts}]`, capped at 30 (oldest dropped first), managed by `serving/demo/purchases.js`. Sent as `purchases` with every `/search` and `/check-link` call.

## Cross-cutting: `/check-link`

**Resolution:** `serving/api/check_link.py` matches `url`'s host + path against `products.store_domain` + a handle parsed from the URL path (`/products/<handle>`); no match → `{"status": "not_in_catalog", ...}`; a match outside men/unisex → `{"status": "department_unsupported", ...}`; both are HTTP 200 (decision 7).

**Fit and alternatives:** on a match, the linked product's sizes are scored directly (unfiltered) for the best size; similar items reuse `ranking/l1.py` with the linked product's own embedding as the query and the normal `ranking/l2.py` scoring, then keep only candidates with `fit_probability >= linked_fit_probability + check_link_fit_margin` (config, starting 0.05), excluding the linked product, capped at 5 (decision 8).

**Logging:** `request_log` gets an `endpoint` column (migration `0006`) so `/check-link` latency is reportable separately from `/search`, still timings/count only.

## Cross-cutting: `results/metrics.csv` mechanics

Each phase owns `eval/phaseN_xxx.py` exposing `run(artifact_version) -> list[MetricRow]`, where `MetricRow = {pillar, method, metric, value, ci_low, ci_high, artifact_version, date}`. `eval/run_all.py` imports every phase module, runs them in order (optionally filtered by `--phase`), and upserts rows into `results/metrics.csv` keyed by `(pillar, method, metric, artifact_version)` — same key overwrites, new key appends. `eval/personalization/metrics.py` reads your exported session JSON from `eval/personalization/sessions/` (gitignored — it's your own browsing history) and computes mean top-5 rating before/after with a bootstrap CI, plus click-to-rating agreement, against the stored `w_style=0` baseline run. `eval/phase6_6_purchases.py` and `eval/phase6_6_checklink.py` follow the same `run(artifact_version) -> list[MetricRow]` contract, writing one row per (dimension, k) for the purchases sensitivity and p50/p95 rows for check-link latency.

## Open items carried from HLD §9 (not blocking, tracked for later phases)

- Initial `ease.yaml` values are placeholders until sanity-checked against the closet set in Phase 3.
- `w_rel`/`w_fit` tuned on the query set (Phase 4); `w_style` and the signal-weight table finalized from the personalization sessions (Phase 6.5).
- Final host confirmed against current free-tier limits at Phase 6 — HF Spaces primary, Render fallback (SPEC §4 decision, not actually open).
- Purchase-correction `k` and the check-link fit margin are starting values (1 and 0.05); Phase 6.6 reports the closet leave-one-out sensitivity across k in {0.5, 1, 2} rather than picking one blindly.

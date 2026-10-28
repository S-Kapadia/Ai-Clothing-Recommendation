# Ai-Clothing-Recommendation: Learning Plan

Replaces the Claude-Code-executes-it framing in `docs/DESIGN.md` §11. You write all
implementation code yourself; this is the roadmap you work through, not a build script.

## How to use this plan

The working model is defined in `CLAUDE.md` — read it first, it's the source of truth and
isn't restated here. In short: concepts before code, you write the implementation, ask for
hints in levels (concept → approach → pseudocode) when stuck, and bring code for review
before ticking a phase's "done when". Boilerplate (Dockerfiles, CI YAML, config) only gets
written for you on request, with every line explained.

Each phase section below has: **concepts** to learn first, **resources** (official docs
preferred, at most two per concept), **tasks** as 1–3 hour checkboxes, the **done when**
check from `docs/DESIGN.md` §11 plus the command that proves it, and project-specific
**pitfalls**.

## Milestones and cut line

- **Milestone A — thin end-to-end (target: Nov 3).** One brand, rules-based charts, the
  body + fit model, simple search, one web page. Goal: something real works, start to finish,
  before deepening anything.
- **Milestone B — deepening (target: Nov 11, priority order):**
  1. Ollama normalization
  2. Auth
  3. H&M style model
  4. Learned ranker
  5. CI/CD + deploy
- **Cut line.** Anything not finished by Nov 11 moves to Stretch below. Nothing already
  working gets broken to make room for something new.

---

## Milestone A — Thin end-to-end

### Phase 0 — Scaffold + database

**Concepts**
- Migrations as versioned, repeatable schema changes — why not just edit tables by hand.
- Postgres row-level security (RLS): policies are predicates evaluated per row, enforced
  regardless of which client is asking.
- What `supabase start` actually boots (Postgres, GoTrue auth, PostgREST, Studio) via Docker.
- pytest fixtures and test discovery.
- Docker Compose: service definitions vs image builds.

**Resources**
- Supabase CLI local development docs (official).
- Postgres "Row Security Policies" docs (official).
- pytest "Fixtures" docs (official).

**Tasks**
- [ ] Verify `supabase/config.toml`'s linked project ref is correct; run `supabase init` only if needed.
- [ ] Write migration `0001` — core catalog tables (brands, products, variants, size_charts,
  chart_measurements, variant_measurements) per `docs/DESIGN.md` §4.
- [ ] Write migration `0002` — accounts/style tables (profiles, owned_items,
  style_preferences, extraction_runs, gold_labels, query_labels, request_log) with the RLS
  policies from §4.
- [ ] Set up `conftest.py` with a fixture that connects to local Supabase and resets state
  between tests.
- [ ] Write one smoke test asserting the schema exists and one asserting an RLS policy
  actually blocks a cross-user read.
- [ ] Write a minimal `docker-compose.yml` with `web` and `api` stubs (placeholder containers
  are fine here — real builds are Milestone B's job).

**Done when:** `supabase start`, migrations 0001 and 0002 apply, `pytest` passes, Docker
Compose starts `web` and `api`.
Command: `supabase start && supabase db reset && pytest && docker compose up -d web api && docker compose ps`

**Pitfalls**
- Docker Desktop must already be running before `supabase start`, or you get a confusing
  timeout instead of a clear "docker not found".
- RLS blocks your own scripts too unless they use the service-role key — don't "fix" this by
  disabling RLS.
- Migrations apply in filename order; a typo in the numeric prefix silently reorders them.
- `supabase db reset` wipes local data every time — never point it anywhere but local.

### Phase 1 — Crawl + classify (one brand)

**Concepts**
- robots.txt and crawl politeness (rate limits, identifying user agent) — why it matters even
  for public pages.
- API-first collection: check for a Shopify `/products.json` endpoint before scraping HTML.
- Category/department classification as a simple text-classification problem.
- Why you spot-check 50 random products rather than eyeballing everything.

**Resources**
- Shopify Storefront/`products.json` conventions (official Shopify dev docs).
- Python `requests` — a plain `time.sleep`-based throttle is enough; no special library needed.

**Tasks**
- [ ] Pick one Shopify store with a public catalog to start (the partner's shortlist can wait).
- [ ] Confirm `/products.json` is exposed and check `robots.txt`.
- [ ] Write a crawler paginating `/products.json` at ≤1 req/sec with a descriptive User-Agent,
  writing raw JSON to `data/raw/`.
- [ ] Write a rules-based classifier mapping each product to category + department
  (title/tag keyword matching to start).
- [ ] Sample 50 products, label them yourself, and write a script reporting accuracy to
  `results/metrics.csv`.

**Done when (partial — full check needs 5 brands, see Milestone B §B.0):** category and
department accuracy on the 50-product spot check reported, for this one brand.
Command: `python -m pipeline.crawl.run --brand <slug> && python -m pipeline.classify.spot_check --brand <slug>`

**Pitfalls**
- Shopify stores vary (some disable `/products.json`, pagination differs) — don't assume this
  brand's shape generalizes until brand 2 in Milestone B.
- Rate-limit sleeps belong around every request, not most of them.
- Don't let unmatched products disappear silently — log and count what the classifier can't categorize.

### Phase 2 — Charts + attributes (rules-based)

**Concepts**
- Size chart normalization: mapping brand-specific labels to a common measurement space.
- Why a rules-based baseline comes before an LLM: it's inspectable, free, and gives you a
  comparison point later.
- The 11-attribute vocabulary (category, department, fit_type, colour_family, pattern,
  fabric, stretch, neckline_collar, sleeve_length, leg_shape, formality).

**Resources**
- `docs/DESIGN.md` §3 (attribute vocabulary and allowed values) — reread it closely here.

**Tasks**
- [ ] Write a rules-based size chart parser for this brand's chart → `chart_measurements` rows.
- [ ] Write rules-based attribute extraction (keyword/regex against title+description+tags)
  for all 11 attributes.
- [ ] Run it over every product for this brand; confirm no product is left all-null.
- [ ] Save raw extraction output to `extraction_runs` — keep the schema identical to what the
  LLM path will use in Milestone B.

**Done when (partial — gold-set comparison and quantization benchmark are Milestone B §B.1):**
attributes filled for every product, this brand.
Command: `python -m pipeline.classify.attributes --brand <slug> --method rules && python -m pipeline.classify.coverage_check --brand <slug>`

**Pitfalls**
- Rules-based fabric/pattern extraction will have real gaps — don't over-invest; Milestone B
  replaces/compares against it.
- A schema mismatch between rules and future LLM extraction runs turns the gold-set
  comparison into a reconciliation headache.

### Phase 3 — Body + fit models

**Concepts**
- Ridge regression: the L2 penalty's effect with correlated anthropometric features, and
  bias-variance tradeoff intuition.
- ANSUR II as a proxy dataset for general body-measurement correlations.
- Fit modeling as ease (garment − body) turned into a word ("snug"/"true to size"/"loose")
  and a probability.
- Bayesian updating: how a known owned-item fit outcome should sharpen, not replace, a
  height-only body estimate.

**Resources**
- scikit-learn Ridge regression docs (official).
- scikit-learn "Underfitting vs Overfitting" example (official) for the bias-variance intuition.

**Tasks**
- [ ] Load ANSUR II, pick the target dimensions per `docs/DESIGN.md` §6.1, fit a ridge
  regression per dimension from height (+ a couple other easy inputs).
- [ ] Report ANSUR MAE vs a height-only baseline to `results/metrics.csv`.
- [ ] Implement the ease formula and fit-word bands from §6.2.
- [ ] Implement the fit probability formula; produce fit words/probabilities for every
  variant of this brand.
- [ ] Implement the Bayesian update for when a user has an owned item with a known outcome.

**Done when:** ANSUR MAE vs height-only reported; fit words and probabilities produced for
every variant.
Command: `python -m models.body.train && python -m models.fit.evaluate >> results/metrics.csv`

**Pitfalls**
- ANSUR II has separate male/female population files — decide which you're using and say so
  in the README; don't silently merge them.
- A good ANSUR held-out MAE doesn't guarantee a good proxy for real shoppers — treat it as a
  sanity check, not a guarantee.
- Watch for cm/inch mismatches between ANSUR and your size charts — the likeliest silent bug here.

### Phase 5 (partial) — Simple search

**Concepts**
- What a MiniLM sentence embedding captures that keyword search doesn't.
- FAISS as approximate nearest-neighbor search, and why it scales where brute-force
  similarity doesn't.
- Why "simple search" here means retrieval only — no learned re-ranking yet.

**Resources**
- sentence-transformers (MiniLM) official docs.
- FAISS official wiki, "Getting started".

**Tasks**
- [ ] Generate MiniLM embeddings for every product (title + description + attributes), this brand.
- [ ] Build a FAISS index over those embeddings.
- [ ] Write a search function: embed the query, retrieve top-K, return ranked by raw similarity.
- [ ] If you build a feed at this stage, order it by **fit probability only** — there is no
  popularity data for these brands, and the style model doesn't exist yet.

**Done when (partial — NDCG@10 vs BM25 and feed/translation/brand-report are Milestone B
§B.4):** simple search returns relevant-looking results for hand-tried queries on this brand.

**Pitfalls**
- Don't reach for the LightGBM ranker yet, even if retrieval quality feels mediocre — that's
  deferred to Milestone B priority #4.
- A fit-probability-only feed will look odd (ranking a stylish-but-ill-fitting item last) —
  that's expected, not a bug to patch with an ad hoc style heuristic.

### Phase 6 (partial) — Simple API, no auth

**Concepts**
- FastAPI basics: path/query params, Pydantic models, dependency injection.
- Why a hardcoded demo persona is a legitimate milestone state, not a shortcut to be ashamed
  of — it unblocks the rest of the stack while auth waits for Milestone B.

**Resources**
- FastAPI official tutorial, "First Steps" through "Request Body".

**Tasks**
- [ ] Stand up a FastAPI app with `/v1/search` calling your Phase 5 search function.
- [ ] Add a hardcoded demo persona so `/v1/search` returns fit-aware results without real auth.
- [ ] Write integration tests against local Supabase.

**Done when (partial — full auth/RLS integration tests are Milestone B §B.2):**
`/v1/search` works end-to-end for the demo persona, with passing tests.
Command: `pytest tests/integration/test_search.py`

**Pitfalls**
- Keep the hardcoded persona behind a clearly named flag/fixture so it's easy to remove once
  B.2 lands — don't let it leak into the real auth code path.

### Phase 7 (partial) — One web page

**Concepts**
- Minimal Vite+React setup: what the dev server does vs a bundler-only workflow.
- CORS basics for calling a local API from a dev frontend.

**Resources**
- Vite official "Getting Started".
- FastAPI `CORSMiddleware` docs (official).

**Tasks**
- [ ] Scaffold a Vite+React+TypeScript app with one route: `/search`.
- [ ] Build a search box + result list calling your FastAPI `/v1/search`.
- [ ] Confirm it runs locally end-to-end: query in, ranked results with fit words out.

**Done when (partial — CI/deploy is Milestone B §B.5):** the one page runs locally and shows
real search results end-to-end for the demo persona.

**Pitfalls**
- Don't add TanStack Query, a generated API client, or routing libraries yet — the full
  frontend stack in `docs/DESIGN.md` §8 is a Milestone B concern; one page needs none of it.

### Phase 8 (partial) — README v1

**Concepts**
- A README's job here: let a stranger understand the problem, see it work, and run it, in
  under five minutes of reading.

**Tasks**
- [ ] Write README v1: problem statement, a screenshot/gif of the one working page, a simple
  architecture diagram, a results table (ANSUR MAE, attribute coverage, spot-check accuracy),
  and how-to-run steps for exactly what exists today.

**Done when:** README v1 exists and someone could follow it to run the thin slice end-to-end locally.

**Pitfalls**
- Don't describe features that don't exist yet (auth, 5 brands, style model) as if done —
  update incrementally in Milestone B, not by over-promising now.

---

## Milestone B — Deepening (priority order)

### B.0 — Scale to 5 brands (mechanical, do first)

Not a numbered `docs/DESIGN.md` phase on its own — it's what actually satisfies Phase 1's
real done-when (5 brands) and unlocks everything else in Milestone B that needs multi-brand
data (style model, size translation, brand report, NDCG eval).

**Tasks**
- [ ] Get the partner's brand shortlist (or pick 4 more Shopify stores yourself if it isn't
  ready) and re-run the Phase 1 crawler + classifier on each.
- [ ] Re-run Phase 2's rules-based extraction on each new brand.
- [ ] Re-run Phase 3's fit model against each brand's size chart.

**Done when (completes Phase 1's real done-when):** 5 brands crawled; category and department
accuracy on the 50-product spot check reported, for all 5.

**Pitfalls**
- This is where brand-specific quirks surface (different chart table shapes, different
  Shopify API variants) — budget real time even though it's "mechanical".

### B.1 — Ollama normalization (priority #1, deepens Phase 2)

**Concepts**
- Structured extraction via a local LLM: why JSON-schema-constrained generation beats
  free-text parsing.
- Quantization tradeoffs: what 4-bit buys/costs, and why you benchmark 7B vs 3B rather than
  assume bigger wins.
- Caching LLM calls by (model, prompt version, input hash) as a correctness requirement for
  reproducible metrics, not just a speed optimization.

**Resources**
- Ollama official docs (structured/JSON output mode).
- qwen2.5 model card on the Ollama library page (7B and 3B variants).

**Tasks**
- [ ] Set up Ollama with qwen2.5:7b-instruct and the 3B variant, 4-bit, temp 0.
- [ ] Design the JSON schema and prompt for attribute extraction per `docs/DESIGN.md` §3/§5.
- [ ] Implement the disk cache keyed by model+prompt_version+input_hash; verify a repeated
  call never re-hits Ollama.
- [ ] Run LLM extraction across all 5 brands; save raw outputs to `extraction_runs`.
- [ ] Run the gold-set precision comparison (LLM vs rules-only) — gold labels already exist,
  don't regenerate them.
- [ ] Run the 7B vs 3B benchmark (precision + latency); write both to `results/metrics.csv`.

**Done when:** gold-set precision vs rules-only and the 7B vs 3B benchmark in
`results/metrics.csv`; attributes filled for every product across all 5 brands.
Command: `python -m pipeline.classify.attributes --method llm --all-brands && python -m eval.run_all --suite attributes`

**Pitfalls**
- A cache key missing the prompt version will silently serve stale extractions after you edit
  a prompt — verify the key covers everything that affects output.
- VRAM limits can make the 7B model unusably slow; the benchmark exists to find that out, not
  to assume the bigger model wins.

### B.2 — Auth (priority #2, deepens Phase 6)

**Concepts**
- Supabase magic-link auth and what a Bearer token actually proves to the API.
- RLS as defense-in-depth: the API should still check resource ownership even though the DB
  would also block it.

**Resources**
- Supabase Auth docs, magic link / email OTP (official).
- FastAPI "Security" tutorial section (official), for a Bearer token dependency.

**Tasks**
- [ ] Wire Supabase magic-link auth into the API (verify Bearer token, extract user id).
- [ ] Replace the hardcoded demo persona with real profile/owned-items/style-preferences
  reads, scoped by RLS.
- [ ] Write integration tests confirming one user cannot read another's profile/owned items.
- [ ] Keep the demo persona path alongside real auth (it's the recruiter/visitor flow in
  `docs/DESIGN.md` §1, not leftover scaffolding).

**Done when:** all endpoints pass integration tests, including RLS.
Command: `pytest tests/integration/ -k auth_or_rls`

**Pitfalls**
- A passing suite that never attempts a cross-user access proves nothing about RLS — write
  the negative test explicitly.

### B.3 — H&M style model (priority #3, Phase 4)

**Concepts**
- Training a style model on H&M's Personalized Fashion dataset, then transferring it to 5
  much smaller brand catalogs — and why that transfer might not work (flagged as a real risk
  in `docs/DESIGN.md` §12).
- Logistic regression vs LightGBM for this signal — when the extra complexity is worth it.

**Resources**
- LightGBM official docs, "Python Quick Start".
- scikit-learn `LogisticRegression` docs (official), as the baseline to beat.

**Tasks**
- [ ] Prepare the H&M dataset per `docs/DESIGN.md` §6.3; train a logistic regression baseline.
- [ ] Train the LightGBM version and compare.
- [ ] Apply the trained model to your 5 brands' catalogs; sanity-check outputs make sense.
- [ ] Report Recall@12 and MAP@12 vs a popularity baseline (H&M has popularity data, even
  though your 5 brands don't) to `results/metrics.csv`.

**Done when:** Recall@12 and MAP@12 vs popularity reported.
Command: `python -m models.style.train && python -m eval.run_all --suite style`

**Pitfalls**
- `docs/DESIGN.md` §12 already flags this phase as most likely to run long — if transfer to
  the 5 brands looks weak, report that honestly rather than chasing it indefinitely.
- Check H&M's Kaggle license terms before committing any derived artifacts (open question in
  §12); never commit the raw dataset regardless.

### B.4 — Learned ranker + feed/translation/brand report (priority #4, deepens Phase 5)

**Concepts**
- Learning to rank: why LambdaRank optimizes a ranking metric (NDCG) directly instead of
  treating ranking as plain regression/classification.
- Feature design for the ranker: the signals (retrieval score, fit probability, style score)
  in the final score formula from `docs/DESIGN.md` §6.5.

**Resources**
- LightGBM official docs, LambdaRank / ranking objective section.

**Tasks**
- [ ] Build the feature set per §6.5 (retrieval score, fit probability, style score from B.3).
- [ ] Train the LambdaRank ranker on your existing query label set.
- [ ] Report NDCG@10 vs a BM25 baseline to `results/metrics.csv`.
- [ ] Implement the "for you" feed, size translation, and brand fit report using the complete
  fit+style+ranking stack, across all 5 brands.
- [ ] Confirm feed/translation/brand-report all work in tests.

**Done when:** NDCG@10 vs BM25 reported; feed, size translation and brand report work in tests.
Command: `python -m models.ranker.train && python -m eval.run_all --suite ranking && pytest tests/integration/test_feed.py tests/integration/test_translate.py tests/integration/test_brand_report.py`

**Pitfalls**
- Too few labeled queries is a named risk (§12) — a suspiciously perfect train-set NDCG is a
  reason to check for leakage, not celebrate.

### B.5 — CI/CD + deploy (priority #5, deepens Phase 7)

**Concepts**
- What CI actually buys you (lint/type/test on every push) beyond running checks locally.
- Multi-stage Docker builds, and why `serving/` must stay LLM/PyTorch-free (onnxruntime+NumPy
  only) per `CLAUDE.md`.
- Static frontend (Vercel) vs containerized API (Hugging Face Spaces) deployment models.

**Resources**
- GitHub Actions official docs, "Quickstart".
- Docker official docs, "Multi-stage builds".

**Tasks**
- [ ] Flesh out `docker-compose.yml` for real `web`/`api` builds (this is boilerplate — ask
  for it per `CLAUDE.md`'s rule, with every line explained).
- [ ] Write `.github/workflows/ci.yml`: lint, type-check, pytest, integration tests against a
  local Supabase service container.
- [ ] Build and run the serving image locally; confirm onnxruntime+NumPy only, no torch, no
  LLM calls, before deploying.
- [ ] Deploy the API to Hugging Face Spaces and the frontend to Vercel on merge to main.
- [ ] Wire up structlog and a `/metrics` endpoint per `docs/DESIGN.md` §9.

**Done when:** CI green; live demo works with a persona.

**Pitfalls**
- A stray `import torch` or cached LLM client can slip into `serving/` during refactors — CI
  should fail loudly on this, not rely on code review to catch it.
- Free-tier hosting memory limits are a named risk (§12) — check current limits before
  assuming the deploy fits.

### B.6 — README v2 (update, Phase 8 remainder)

**Tasks**
- [ ] Update the README from v1 to reflect Milestone B: 5 brands, auth, style model, learned
  ranker, CI/CD, deploy link.
- [ ] Refresh the results table with the final `results/metrics.csv` numbers.
- [ ] Add the live demo link and a persona walkthrough.

**Done when:** README reflects the actual final state of the project, with a working live
demo link.

---

## Stretch

Cut line: anything below is what gets deferred if Milestone B isn't fully done by Nov 11 —
deferring it never breaks what's already built.

- Load test (Locust) — p50/p95 latency numbers in `results/metrics.csv` (Phase 8 remainder).
- ADRs in `docs/adr/` (Phase 8 remainder).
- Closet set.
- MCP.
- Extra quantization configs beyond the 7B/3B benchmark.
- Partner-owned items not yet delivered: brand shortlist beyond what B.0 needed, ease
  reference values, H&M menswear exploration, query set draft, the Locust load test itself.
- `docs/DESIGN.md` §12 open questions, carried over:
  - [ ] Which 5 brands? (partner shortlist due first)
  - [ ] Is the attribute vocabulary in §3 final?
  - [ ] Ease values and thresholds t1, t2 per dimension (partner's reference table)
  - [ ] Do H&M's Kaggle terms allow use in a public portfolio repo if the data itself is never committed?
  - [ ] Final hosting tier after checking current limits

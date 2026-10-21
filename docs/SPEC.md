# Ai-Clothing-Recommendation: SPEC v1.1

**Status:** v1.1, 2026-10-21. Architecture lives in `docs/HLD.md`. This spec fixes *what* gets built and *when it is done*. Plan mode decides file-level detail.

## 1. Problem and goal

Size labels are inconsistent across brands: "M" at one brand differs from "M" at another in chest, length and sleeve. Shoppers guess, buy multiple sizes and return them; fit is the top reason for apparel returns. Personal origin: I am tall and slim, so a size that fits my chest is usually short.

**Goal:** fit-aware, personalized search across Shopify apparel brands. Every brand's sizes are converted into real measurements, and results are ranked by relevance, predicted fit and the shopper's demonstrated style, with the size to buy and a plain reason.

**Design anchor:** Shopify Semantic Search (Vantage): L1 retrieval, then L2 re-ranking.

| Pillar | Job | Vantage equivalent |
| --- | --- | --- |
| 1. Size normalization | Turn every brand's size chart into measurements per size | Catalog enrichment |
| 2. L1 retrieval | Find matching items; drop items with no size that could fit | L1 retrieval with embeddings |
| 3. Fit model + L2 ranking | Predict fit per measurement; pick the size; rank by fit, relevance and personal style | L2 re-ranking |

## 2. User flow

1. Open the demo page ("warming up" message if the server is asleep).
2. Enter height and weight (remembered in the browser). Choose Men or Women (Women shows "coming soon" in v1).
3. Type a search; optionally pick a category (t-shirt, shirt, pants, shorts).
4. See result cards: photo, brand, item, **size to buy**, overall fit rating, a fit word per measurement, a one-line reason, link to the store.
5. Items with no fitting size are hidden.
6. Click a result to open it; the card then asks "How much do you like this? 1 to 5". Clicks and ratings are saved in the browser, and later searches lean toward styles rated highly.

No accounts, no tape measure, and nothing about the shopper stored on the server.

## 3. Scope

**v1**
- 15 to 20 Canadian and US Shopify apparel stores, one snapshot crawl.
- Categories: t-shirts, shirts, pants, shorts.
- Every product tagged with a department (men / women / unisex). Search and fit cover men's + unisex.
- Pillar 1: size-chart normalization.
- Pillar 2: text-only L1 retrieval with category, department and fit filters.
- Pillar 3: per-measurement fit model and L2 ranking.
- Style personalization (Phase 6.5): clicks and 1 to 5 ratings stored in the browser, sent with each search, used as a style term in L2.
- Evaluation harness for every pillar, with baselines.
- FastAPI search API on free hosting; static demo page; README with the results table.

**Stretch, in priority order**
1. Local LLM re-rank of the top 20, measured in evaluation (local mode only).
2. Image embeddings (CLIP) in L1.
3. Reference-garment input ("I own an M from Brand A"); it also pre-selects department.
4. Women's fit support: ANSUR female body model, about 20 women's garments of closet data, women's ease values.
5. Friends' closet data (men's).
6. Image-only size charts.
7. Accounts: login, cross-device profile, server-side click and rating history, delete-my-data option.

**Non-goals:** accounts in v1, server-side storage of shopper data, women's fit predictions in v1, outerwear or footwear, live catalog refresh, any LLM on the deployed server, real-user traffic.

## 4. Decisions

| Topic | Decision |
| --- | --- |
| Shopify anchor | Semantic Search (Vantage) |
| LLM | Local quantized models via Ollama on an RTX 4060 (to confirm); offline only |
| Catalog | One snapshot plus a re-run script |
| Search | Text-only in v1 |
| Department | Products tagged men / women / unisex; v1 searches men's + unisex; women's fit is stretch |
| Fit labels | Per measurement, five coarse words (section 5) |
| Body-measurement charts | Converted to garment measurements with a fixed ease per category and dimension |
| Pants and shorts | Ignore the label number; use chart measurements |
| Profile input | Height + weight; reference garment is stretch |
| Closet set | 20 of my own garments now; friends later |
| Accounts | None in v1; profile, clicks and ratings live in the browser and are sent with each request; accounts are stretch |
| Personalization | Style profile built per request from clicked and rated products' embeddings; no server-side storage |
| Rating scale | 1 to 5, asked only after a click |
| Repo | Convert `AI-Advertisement-Recommendation`, rename to `ai-clothing-recommendation` |
| Hosting | Hugging Face Spaces (Docker, free CPU), fallback Render; demo page on GitHub Pages |
| Docker | Local Supabase for development; serving image built and tested locally before deploy. Pipeline and Ollama run natively |

## 5. Pillar requirements and acceptance criteria

### Pillar 1: size normalization

**Dimensions (cm).** Tops: chest (full circumference), body length, sleeve; shoulder if available. Bottoms: waist (full), hip (full), inseam; rise if available.

**Classification (before normalization).** Each product gets a category (t-shirt, shirt, pants, shorts, other) and a department (men, women, unisex). Rules on product type, tags, title and collection names first; local LLM for unclear products. "Other" is dropped.

**Pipeline**
1. Locate the chart: description HTML table, description text, size-guide page, or image. Deduplicate by content fingerprint.
2. Clean HTML tables go to the rules parser.
3. Everything else goes to the local LLM, constrained by a JSON schema built from that product's actual size list, so every listed size must get a row.
4. A second LLM pass reviews the extraction and flags issues.
5. Validators: sizes increase in order; values in plausible ranges per dimension; inches converted to cm; half measurements ("pit to pit", flat waist) doubled; measurement basis recorded (garment or body).
6. Body-basis charts are converted to garment measurements by adding the fixed ease from config.
7. Failures are marked *abstained* and excluded from search.

**Acceptance**
- At least 90% field precision on a gold set of **50 hand-labelled charts**, stratified by source type.
- Abstain rate reported.
- Baseline: rules-only parser.
- Classifier: category and department accuracy reported on a 50-product spot check.

### Pillar 2: L1 retrieval

- Text embedding per product from title, product type, tags and cleaned description.
- Exact FAISS index; product IDs kept in a separate ID map.
- At query time: embed the query, retrieve the top 200, then apply the category filter, the department filter (requested department + unisex), and the fit filter (drop products where no size is predicted at least "a bit" in every dimension).

**Acceptance**
- Recall@50 and NDCG@10 on a **50-query set** with graded relevance labels (0, 1, 2), labelled from pooled results.
- Baseline: keyword search (BM25).

### Pillar 3: fit model and L2 ranking

**Body profile.** Regression models trained on ANSUR II (male subset in v1) predict chest, waist, hip, arm length, torso length and inseam from height and weight. The mapping from ANSUR fields to these dimensions lives in config.

**Fit labels (ordinal, five words)**

| Widths (chest, waist, hip) | Lengths (body, sleeve, inseam) |
| --- | --- |
| too tight | too short |
| a bit tight | a bit short |
| just right | just right |
| a bit loose | a bit long |
| too loose | too long |

**Fit model**
- For each dimension: difference = garment measurement minus body measurement.
- One ordinal model per dimension type, with category-level ease as an offset. Few parameters, sized for 20 garments.
- Fallback: hand-set thresholds in config.

**Size choice and ranking**
- Choose the size that maximizes the probability that every dimension is "a bit" or "just right".
- L2 score = w_rel x relevance + w_fit x fit probability + w_style x style similarity. Weights in config; w_rel and w_fit tuned on the query set; w_style is 0 when the shopper has no style profile.

**Explanations.** Templates from the predicted words, e.g. "Get the L: chest just right, length a bit long. The M would be too short."

**Acceptance**
- Leave-one-out accuracy per dimension on the closet set (exact word and within one step), with confidence intervals. Baseline: the fixed thresholds.
- Body estimator: MAE in cm per dimension on an ANSUR holdout. Baseline: height-only regression.

### Style personalization (Phase 6.5, part of L2)

**Signals** (sent by the browser with each search; most recent 50 kept):

| Signal | Weight (config, starting values) |
| --- | --- |
| Rated 5 | +1.0 |
| Rated 4 | +0.5 |
| Rated 3 | 0 |
| Rated 2 | -0.5 |
| Rated 1 | -1.0 |
| Clicked, not rated | +0.25 |

**Style profile.** Computed on the server per request, never stored: the weighted sum of the clicked and rated products' text embeddings, normalized. Applied only once the shopper has at least 3 signals; unknown product IDs are ignored.

**Style similarity.** Cosine similarity between each candidate's embedding and the style profile, used as the third L2 term. Products the shopper already rated are not boosted again.

**Acceptance** (single user, me; stated as such in the README)
- Fixed set of 10 queries. Before personalization: rate the top 5 results for each. After at least 20 further ratings on other searches: rerun the same queries and rate the new top 5.
- Report mean top-5 rating before vs after, with a confidence interval.
- Report click-to-rating agreement: share of clicked items rated 4 or 5.
- Baseline: the same ranking with w_style = 0.

## 6. Data and labelling

| Dataset | Source | Owner | Due |
| --- | --- | --- | --- |
| Store shortlist (30 to 40, vetted to 15 to 20) | Manual research + vetting script | Me | Oct 22 |
| Catalog snapshot | Public `products.json` + size-guide pages | Crawler | Oct 22 |
| ANSUR II | Public download | Pipeline | Oct 26 |
| Closet set: 20 garments (about 12 tops, 8 bottoms, including bad fits) + my body measurements | My wardrobe, measured flat with a tape | Me | Oct 25 |
| Gold set: 50 charts | Hand-labelled from crawled charts | Me | Oct 24 |
| Classifier spot check: 50 products | Hand-labelled category + department | Me | Oct 24 |
| Query set: 50 queries, graded | Written by me; labels on pooled results | Me | Oct 28 |
| Personalization sessions: 10 fixed queries + 20 or more ratings | My use of the demo, exported from the browser as JSON | Me | Nov 1 |

**Closet record per garment:** brand, item, size label, category, flat measurements (doubled where half), fit word per measurement, overall verdict (wear / wear but flawed / don't wear).

## 7. API contract

`POST /search`

```json
{"height_cm": 188, "weight_kg": 72, "query": "black chinos",
 "department": "men", "category": "pants", "k": 10,
 "liked": [{"product_id": "123", "signal": "rating", "value": 5},
           {"product_id": "456", "signal": "click"}]}
```

`department` defaults to `men`; `women` returns an empty result with a "coming soon" message in v1. `category` is optional. `liked` is optional, capped at 50 entries; unknown product IDs are ignored.

Response:

```json
{"catalog_snapshot": "2026-10-22", "artifact_version": "v1",
 "personalized": true,
 "results": [{"product_id": "...", "title": "...", "brand": "...",
   "image_url": "...", "product_url": "...", "size": "32x34",
   "fit_probability": 0.82, "style_score": 0.61,
   "fit": {"waist": "just right", "hip": "a bit loose", "inseam": "just right"},
   "reason": "Get the 32x34: waist just right, inseam just right. The 32x32 would be too short."}],
 "timings_ms": {"profile": 2, "l1": 40, "l2": 15, "style": 3, "total": 63}}
```

`GET /health` returns status, artifact version and catalog snapshot date.

The request log stores timings and result counts only, never height, weight, query text, clicks or ratings. CORS is limited to the demo page origin.

## 8. Demo page

One static page: height and weight inputs (saved to browser local storage), Men / Women toggle, search box, category picker. Result cards as in section 2, a warm-up message, and a "catalog as of" date. Images load from store URLs; every card links to the original product page.

**Personalization controls:**
- Clicking a card's store link records a click and shows a 1 to 5 rating prompt on that card.
- Clicks and ratings are kept in local storage and sent with each search.
- "Personalized for you" label when a style profile is active.
- "Clear my history" button.
- "Export my history" button (JSON download), used for the personalization evaluation.

## 9. Evaluation

One command (for example `python -m eval.run_all`) regenerates `results/metrics.csv` with columns: pillar, method, metric, value, ci_low, ci_high, artifact_version, date. Every README number comes from this file, including the personalization metrics computed from the exported session JSON. A new version ships only if no metric drops.

## 10. Non-functional requirements (detail in HLD)

Search under 2 s when the server is warm; cold start up to 60 s acceptable. The full offline pipeline runs overnight on my PC. $0 LLM cost. Development runs against local Supabase in Docker; the serving image is tested locally before deploy. Reproducible results: snapshot dates, seeds, versioned prompts, saved LLM outputs. Polite crawling: robots.txt respected, 1 request per second, catalogs never republished. Nothing about shoppers stored on the server: profiles, clicks and ratings live only in the browser.

## 11. Repo layout (starting point; plan mode may refine)

```
docs/          SPEC.md, HLD.md, PLAN.md
config/        stores.yaml, dimensions.yaml, ease.yaml, fit_thresholds.yaml, classifier_rules.yaml, ranking.yaml
pipeline/      crawl/, classify/, charts/, normalize/, variants/
models/        body/, fit/, embed/, style/
serving/       api/, demo/
eval/          gold/, closet/, queries/, personalization/, run_all.py
data/          raw/, interim/        (gitignored)
artifacts/     vN/                   (gitignored, built by script)
results/       metrics.csv
supabase/      migrations/
```

## 12. Phases and timeline (ML ships Nov 2)

| Phase | Dates | Builds | Done when |
| --- | --- | --- | --- |
| 0 | Oct 21 | Repo conversion, scaffold, local Supabase in Docker, migrations applied locally | `supabase start` works; migrations apply; tests run |
| 1 | Oct 22 | Store vetting, crawler, category + department classifier | 15 to 20 stores crawled; products classified; spot-check accuracy reported |
| 2 | Oct 23 to 25 | Chart locator, rules parser, LLM extract + review, validators, variant mapper | Gold-set precision reported vs rules-only |
| 3 | Oct 26 | Body estimator, fit model | ANSUR MAE and closet leave-one-out accuracy reported |
| 4 | Oct 27 to 28 | Embeddings, L1 with filters, L2 ranking | Query-set Recall@50 and NDCG@10 vs BM25 |
| 5 | Oct 29 | `run_all` evaluation, artifact bundle | One command regenerates every metric |
| 6 | Oct 30 | API, demo page, serving image tested locally in Docker, deploy | Local container and live demo both return results |
| 6.5 | Oct 31 to Nov 1 | Style personalization: `liked` input, style profile, L2 style term, rating prompt, clear and export buttons | Personalization metrics in `results/metrics.csv` vs w_style = 0 |
| 7 | Nov 2 | README, buffer | Results table and diagram published |

Evaluation is built inside each phase, not saved for the end. If the timeline slips, cut the query set to 30 first; if it slips further, Phase 6.5 moves to stretch without affecting phases 0 to 6.

## 13. My tasks (not Claude Code's)

- [ ] Confirm GPU and run one 7B model in Ollama (Oct 21)
- [ ] Install Docker Desktop (WSL2) (Oct 21)
- [ ] Shortlist stores (Oct 22)
- [ ] Label 50 gold charts and the 50-product classifier spot check (by Oct 24)
- [ ] Measure 20 garments + my body (by Oct 25)
- [ ] Write and label 50 queries (by Oct 28)
- [ ] Run personalization sessions: 10 fixed queries before, 20 or more ratings, same queries after; export history (by Nov 1)
- [ ] Review every migration and push it to the hosted DB
- [ ] Check git history for secrets before making the repo public

## 14. Open items

- Initial ease values per category and dimension (config; sanity-checked against the closet set).
- L2 weights: w_rel and w_fit tuned on the query set; w_style and the signal weights set from the personalization sessions.
- Final host after checking current free-tier limits.
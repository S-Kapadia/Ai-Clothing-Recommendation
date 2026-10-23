# Ai-Clothing-Recommendation: SPEC v1.2

**Status:** v1.2, 2026-10-22. Architecture lives in `docs/HLD.md`. This spec fixes *what* gets built and *when it is done*. Plan mode decides file-level detail.

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
7. Add owned garments under "My purchases": pick store, product and size from the catalog, give a fit word per measurement and an overall verdict. Saved in the browser; sent with each search and used to correct the body estimate and as a style signal.
8. Paste a product URL into "Check a link" to get its size, fit and up to 5 better-fitting alternatives from other stores — or a plain message if the store or product isn't in the catalog yet.

No accounts, no tape measure, and nothing about the shopper — including purchases or pasted URLs — stored on the server.

## 3. Scope

**v1**
- 15 to 20 Canadian and US Shopify apparel stores, one snapshot crawl.
- Categories: t-shirts, shirts, pants, shorts.
- Every product tagged with a department (men / women / unisex). Search and fit cover men's + unisex.
- Pillar 1: size-chart normalization.
- Pillar 2: text-only L1 retrieval with category, department and fit filters.
- Pillar 3: per-measurement fit model and L2 ranking.
- Style personalization (Phase 6.5): clicks and 1 to 5 ratings stored in the browser, sent with each search, used as a style term in L2.
- Portable fit profile (Phase 6.6): self-reported purchases correct the body estimate and count as style signals; "check a link" sizes a pasted catalog product URL and suggests better-fitting alternatives.
- Evaluation harness for every pillar, with baselines.
- FastAPI search API on free hosting; static demo page; README with the results table.

**Stretch, in priority order**
1. Local LLM re-rank of the top 20, measured in evaluation (local mode only).
2. Image embeddings (CLIP) in L1.
3. Women's fit support: ANSUR female body model, about 20 women's garments of closet data, women's ease values.
4. Friends' closet data (men's).
5. Image-only size charts.
6. Accounts: login, cross-device profile, server-side click and rating history, delete-my-data option.
7. "Check a link" for any Shopify store not in the catalog, fetching /products/<handle>.json live and using the rules parser only (no LLM on the server).
8. Browser extension that shows the size on the product page itself.
9. Non-Shopify stores.
10. Automatic purchase import (order emails or store accounts).

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
| Profile input | Height + weight, blended per dimension with purchase-implied measurements (weight n/(n+k) toward purchases, n = purchases informing that dimension, k in config); height + weight alone when n = 0 |
| Closet set | 20 of my own garments now; friends later |
| Accounts | None in v1; profile, clicks and ratings live in the browser and are sent with each request; accounts are stretch |
| Personalization | Style profile built per request from clicked and rated products' embeddings; no server-side storage |
| Rating scale | 1 to 5, asked only after a click |
| Purchases | Self-reported, browser-only, capped at 30 entries; unknown product IDs ignored; also scored as a style signal |
| Check a link | Catalog stores only in v1, matched by store domain + product handle; unknown store/product or unsupported department returns a 200 with a status message, not an error |
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

### Portable fit profile (Phase 6.6)

**Purchases.** On the demo page, the shopper adds owned garments under "My purchases": store, product and size picked from the crawled catalog, a fit word per measurement (this section's five-word scale) and an overall verdict (wear / wear but flawed / don't wear — the same three options as the closet set). Stored only in the browser, sent with each request as the optional `purchases` field (section 7), capped at 30 entries; unknown product IDs are ignored.

**Body-estimate correction.** For each dimension, each surviving purchase that reports a fit word on a known garment measurement implies a body measurement, by inverting the same fit-word thresholds the fit model uses. When n purchases inform a dimension, the body estimate for that dimension is a weighted average of the mean purchase-implied value and the height + weight (ANSUR) estimate, with weight n / (n + k) on the purchase-implied value; k is a config value (`config/ranking.yaml`, starting k = 1, so one purchase weighs 50/50 against height + weight, two purchases 2:1, and so on). With zero purchases on a dimension (n = 0), the height + weight estimate is used unchanged. This replaces stretch item "reference-garment input" from v1.1; it is now in v1.

**Purchases as style signal.** Each surviving purchase's verdict feeds the same per-request style profile as `liked` (style personalization, above): `wear` = +1.0, `wear but flawed` = 0, `don't wear` = -1.0 (starting values, config, tuned alongside the rating weights).

**Check a link.** `POST /check-link` (section 7) takes a product URL plus the same profile fields as `/search`. The URL is matched to a catalog product by store domain and product handle; only stores in the crawled catalog are supported in v1. An unmatched store or product, or a product in an unsupported department (women's), returns a plain "not in our catalog yet" / "not supported yet" status — an ordinary 200 response, not an error. On a match: the linked product's best size, fit probability and fit word per measurement are computed and returned unfiltered, even if no size fits well — the shopper already has this product in mind, unlike `/search`, which hides non-fitting items. Up to 5 similar items from other stores that fit better are found by L1 retrieval using the product's own embedding as the query, then the normal L2 ranking, kept only if their fit probability is at least a margin above the linked product's own best-size fit probability (margin in config, starting 0.05), excluding the linked product itself.

**Acceptance**
- Purchases: leave-one-out on the closet set, where the other closet items act as the shopper's purchases. Report per-dimension fit accuracy (exact word and within one step) with purchases blended in vs. height + weight only, with confidence intervals, for k in {0.5, 1, 2} — the closet set is small, so this is reported as a sensitivity check across k, not a single tuned value.
- Check a link: tests covering a crawled product URL, an unknown store, an unknown product on a known store, and a known product in an unsupported department. End-to-end latency reported from `request_log` (section 7).

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

Phase 6.6 reuses this closet set for its leave-one-out evaluation and reuses the crawled catalog for the check-a-link tests; it needs no new hand-labelled dataset.

## 7. API contract

`POST /search`

```json
{"height_cm": 188, "weight_kg": 72, "query": "black chinos",
 "department": "men", "category": "pants", "k": 10,
 "liked": [{"product_id": "123", "signal": "rating", "value": 5},
           {"product_id": "456", "signal": "click"}],
 "purchases": [{"product_id": "789", "size": "32x34",
                "fit": {"waist": "just right", "inseam": "a bit short"},
                "verdict": "wear"}]}
```

`department` defaults to `men`; `women` returns an empty result with a "coming soon" message in v1. `category` is optional. `liked` is optional, capped at 50 entries; unknown product IDs are ignored. `purchases` is optional, capped at 30 entries; unknown product IDs are ignored. Each purchase's fit words correct the body estimate (section 5) and its verdict feeds the style profile alongside `liked`.

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

`POST /check-link`

```json
{"url": "https://store.example.com/products/slim-chino",
 "height_cm": 188, "weight_kg": 72,
 "liked": [], "purchases": []}
```

Response, when the URL matches a catalog product in a supported department:

```json
{"status": "ok", "catalog_snapshot": "2026-10-22", "artifact_version": "v1",
 "product": {"product_id": "789", "title": "...", "brand": "...", "store": "store.example.com",
   "size": "32x34", "fit_probability": 0.74,
   "fit": {"waist": "just right", "inseam": "a bit short"},
   "reason": "Get the 32x34: waist just right. Runs a bit short in the inseam."},
 "similar": [{"product_id": "...", "title": "...", "brand": "...", "store": "...",
   "size": "...", "fit_probability": 0.88, "fit": {"...": "..."}, "reason": "..."}],
 "timings_ms": {"profile": 2, "resolve": 5, "l1": 35, "l2": 12, "total": 54}}
```

`status` is `"not_in_catalog"` when the store or product isn't in the crawled catalog, or `"department_unsupported"` for a known women's product (the same case `/search`'s `department=women` covers) — both are ordinary 200 responses with a `message` field, never an error. `similar` holds up to 5 items whose `fit_probability` is at least `check_link_fit_margin` (config, starting 0.05) above the linked product's own best-size `fit_probability`, excluding the linked product itself.

`GET /health` returns status, artifact version and catalog snapshot date.

The request log stores timings, endpoint and result counts only, never height, weight, query text, URLs, purchases, clicks or ratings. CORS is limited to the demo page origin.

## 8. Demo page

One static page: height and weight inputs (saved to browser local storage), Men / Women toggle, search box, category picker. Result cards as in section 2, a warm-up message, and a "catalog as of" date. Images load from store URLs; every card links to the original product page.

**Personalization controls:**
- Clicking a card's store link records a click and shows a 1 to 5 rating prompt on that card.
- Clicks and ratings are kept in local storage and sent with each search.
- "Personalized for you" label when a style profile is active.
- "Clear my history" button.
- "Export my history" button (JSON download), used for the personalization evaluation.

**Portable fit profile controls:**
- "My purchases" list: add a purchase by picking store, product and size from the catalog, then a fit word per measurement and an overall verdict; remove any purchase. Kept in local storage, capped at 30, sent with each search and check-a-link.
- "Check a link" box: paste a product URL, see its size, fit and up to 5 better-fitting alternatives, or a plain message if the store or product isn't supported yet.

## 9. Evaluation

One command (for example `python -m eval.run_all`) regenerates `results/metrics.csv` with columns: pillar, method, metric, value, ci_low, ci_high, artifact_version, date. Every README number comes from this file, including the personalization metrics computed from the exported session JSON. Phase 6.6 adds the purchases-blend sensitivity (k in {0.5, 1, 2}) and check-link latency to the same file. A new version ships only if no metric drops.

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

## 12. Phases and timeline (ML ships Nov 4)

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
| 6.6 | Nov 2 to Nov 3 | Portable fit profile: `purchases` input, body-estimate blend, purchases as a style signal, `/check-link` endpoint, demo page controls | Purchases leave-one-out accuracy (k sensitivity) and check-link latency in `results/metrics.csv` |
| 7 | Nov 4 | README, buffer | Results table and diagram published |

Evaluation is built inside each phase, not saved for the end. If the timeline slips: cut the query set to 30 first, then move Phase 6.6 to stretch, then Phase 6.5 to stretch. Phases 0 to 6 must not be affected.

## 13. My tasks (not Claude Code's)

- [ ] Confirm GPU and run one 7B model in Ollama (Oct 21)
- [ ] Install Docker Desktop (WSL2) (Oct 21)
- [ ] Shortlist stores (Oct 22)
- [ ] Label 50 gold charts and the 50-product classifier spot check (by Oct 24)
- [ ] Measure 20 garments + my body (by Oct 25)
- [ ] Write and label 50 queries (by Oct 28)
- [ ] Run personalization sessions: 10 fixed queries before, 20 or more ratings, same queries after; export history (by Nov 1)
- [ ] Enter my own purchases on the demo page (Nov 2 to 3)
- [ ] Review every migration and push it to the hosted DB
- [ ] Check git history for secrets before making the repo public

## 14. Open items

- Initial ease values per category and dimension (config; sanity-checked against the closet set).
- L2 weights: w_rel and w_fit tuned on the query set; w_style and the signal weights set from the personalization sessions.
- Purchase-correction k (`config/ranking.yaml`): starting 1, reported for {0.5, 1, 2} against the closet set, since the closet set is too small to trust a single tuned value.
- Check-link "fits better" margin (config): starting 0.05 fit-probability points.
- Final host after checking current free-tier limits.
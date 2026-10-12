# Project Steps

Personal build checklist for the developer. Not instructions for Claude. Not referenced by CLAUDE.md.

## Data flow overview

1. Frontend `OfferWidget` calls api `/recommend`.
2. api fetches candidate offers/user data from MySQL via `api/db/pool.js`.
3. api calls model-service `/score` with user/context + candidates.
4. model-service scores/ranks candidates using `features/` + `models/`.
5. api merges scores with offer data, sorts, returns ranked list.
6. Frontend renders the ranked offers.
7. (Optional) api logs a `recommendation_event` row back to MySQL for analytics/A-B.

## Progress tracker

| Step | Status | Notes |
|---|---|---|
| 1. DB schema + seed data | Not started | |
| 2. Baseline recommender | Not started | |
| 3. FastAPI model service (/score) | Not started | |
| 4. Express API (/recommend) | Not started | |
| 5. Frontend OfferWidget | Not started | |
| 6. Optional: LLM re-ranking, A/B, analytics | Not started | |

---

## 1. DB schema + seed data

Why: everything downstream needs real rows to work against. Design the schema by hand first so the rest of the stack has a concrete contract.

Tasks:
- [ ] Define entities: advertisers/merchants, offers, users/sessions, recommendation_events
- [ ] Write `db/migrations/001_init.sql` with CREATE TABLE statements
- [ ] Add indexes for common lookups (offers by advertiser, events by user/offer)
- [ ] Write a seed migration or seed script with sample advertisers/offers/users
- [ ] Run `npm run migrate` from `db/`
- [ ] Load seed data

Files touched: `db/migrations/001_init.sql`, `db/migrations/002_seed.sql` (or a separate seed script)

Done when: connecting to MySQL and running `SELECT * FROM offers;` (and other tables) returns the seeded rows.

Common pitfalls:
- Designing tables around UI fields instead of what the recommender actually needs
- Missing foreign keys / indexes, causing slow joins later
- Editing an already-applied migration file instead of adding a new numbered one

## 2. Baseline recommender (standalone script/notebook)

Why: prove out a simple scoring/ranking approach against real seeded data before wrapping it in a service. Keep it disposable and fast to iterate.

Tasks:
- [ ] Pull seed data into a script/notebook via direct MySQL query or CSV export
- [ ] Define simple features (category match, recency, popularity)
- [ ] Implement a baseline scoring function (rule-based or simple sklearn model)
- [ ] Eyeball the ranked output for a few sample users

Files touched: scratch script/notebook (not part of the main app yet), may later move into `model-service/features/`, `model-service/models/`

Done when: the script prints a ranked list of offers per sample user that looks reasonable.

Common pitfalls:
- Overfitting to a tiny seed dataset
- Building something too complex before validating the simplest baseline
- Mixing feature logic and scoring logic together, making step 3 harder

## 3. FastAPI model service (/score)

Why: wrap the baseline recommender behind a stable HTTP contract so the API can call it without knowing ML internals.

Tasks:
- [ ] Define request/response schema for `POST /score`
- [ ] Move feature logic into `model-service/features/`
- [ ] Move scoring logic into `model-service/models/`
- [ ] Implement `POST /score` in `model-service/main.py`
- [ ] Test with curl/httpie against a running `uvicorn` instance

Files touched: `model-service/main.py`, `model-service/features/`, `model-service/models/`

Done when: `curl -X POST localhost:8000/score -d '{...}'` returns ranked offer scores matching step 2's output.

Common pitfalls:
- Hardcoding seed-specific values instead of reading from the request payload
- Skipping pydantic input validation, letting bad data through silently
- Response shape not matching what api/ needs in step 4

## 4. Express API (/recommend)

Why: join DB-backed offer/user data with model-service scores into a single endpoint the frontend can call.

Tasks:
- [ ] Implement query logic in `api/routes/recommend.js` (fetch candidates via `api/db/pool.js`)
- [ ] Call model-service `/score` via axios using `MODEL_SERVICE_URL`
- [ ] Merge DB offer data with scores, sort, return top N
- [ ] Mount the route in `api/server.js`
- [ ] Test with curl

Files touched: `api/server.js`, `api/routes/recommend.js`, `api/db/pool.js`

Done when: `curl localhost:3000/recommend?...` returns a JSON list of offers ranked by score.

Common pitfalls:
- N+1 queries fetching offer details per score
- No timeout/fallback when model-service is down or slow
- Field name mismatches between DB rows and model-service response causing silent nulls

## 5. Frontend OfferWidget

Why: surface the recommendation end-to-end in the UI so the whole pipeline can be seen working together.

Tasks:
- [ ] Implement `frontend/src/api/client.ts` to call `/recommend` on the api
- [ ] Implement `frontend/src/components/OfferWidget.tsx` to render returned offers
- [ ] Wire `OfferWidget` into `frontend/src/App.tsx`
- [ ] Handle loading/error/empty states
- [ ] Manually test in browser against running api + model-service + mysql

Files touched: `frontend/src/api/client.ts`, `frontend/src/components/OfferWidget.tsx`, `frontend/src/App.tsx`

Done when: `npm run dev` and opening the app shows real ranked offers fetched from the live api.

Common pitfalls:
- CORS not enabled on the Express api for the Vite dev server origin
- No error state when the api is unreachable (blank screen instead)
- Forgetting to update the api base URL for different environments

## 6. Optional: LLM re-ranking, A/B logic, analytics

Why: enhancements layered on top of a working baseline pipeline, not prerequisites for a working demo.

Tasks:
- [ ] LLM re-ranking: call an LLM API to re-rank/re-write top-N offers before returning
- [ ] A/B logic: add a variant/experiment column, randomly assign users to control/treatment
- [ ] Analytics: build aggregate queries (CTR by offer, by variant) against `recommendation_events`
- [ ] Add a new numbered migration if schema changes are needed

Files touched: `api/routes/recommend.js`, `db/migrations/` (new numbered file), possibly a new `api/routes/analytics.js`

Done when: each sub-feature has its own testable check (e.g. a `SELECT` showing variant distribution, a curl showing re-ranked output differs from baseline).

Common pitfalls:
- LLM calls on the hot path with no timeout/fallback to baseline ranking
- A/B assignment not sticky per user (re-randomizing every request)
- Analytics queries scanning `recommendation_events` without indexes as it grows

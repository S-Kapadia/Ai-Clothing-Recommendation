# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

AI Advert is an AI-powered marketing recommendation plugin. It's a monorepo with four independent subprojects — there is no shared package or shared types between them:

- `frontend/` — React 19 + TypeScript + Vite SPA
- `api/` — Node.js + Express backend/gateway
- `model-service/` — Python + FastAPI ML microservice
- `db/` — MySQL schema, owned by a hand-rolled migration runner (no ORM)

The project is very early-stage: `api/server.js` doesn't mount `api/routes/recommend.js` yet, `model-service` only exposes a `/health` endpoint, `frontend` is close to the stock Vite starter plus two empty stub files (`src/components/OfferWidget.tsx`, `src/api/client.ts`), and no database tables exist yet (`db/migrations/001_init.sql` is an empty placeholder).

## Commands

### api/ (Node/Express)
```
cd api
npm install
npm start          # node server.js — PORT env var, default 3000
```
No test suite is configured (`npm test` is a placeholder that exits 1). No lint script.

### db/ (migrations)
```
cd db
npm install
npm run migrate    # applies pending db/migrations/*.sql files in order
```

### frontend/ (React + Vite)
```
cd frontend
npm install
npm run dev         # vite dev server
npm run build        # tsc -b && vite build
npm run lint          # oxlint
npm run preview
```
No test suite is configured.

### model-service/ (Python + FastAPI)
```
cd model-service
pip install -r requirements.txt
uvicorn main:app --reload
```
No test suite is configured.

### Docker Compose
Only the `mysql` service in `docker-compose.yml` is actually runnable (env vars, port `3306`, persistent volume). The `api`, `model-service`, and `frontend` services declare `build:` directives but have no Dockerfiles yet, so `docker compose up --build` fails for those three. The working local loop is: `docker compose up -d mysql`, then run `api`/`frontend`/`model-service` directly with the commands above.

## Architecture

- **api** is the gateway: `api/server.js` is meant to mount `api/routes/recommend.js`, call `model-service` (via the `MODEL_SERVICE_URL` env var), and read/write MySQL through `api/db/pool.js`, returning recommendation/offer data to the frontend's `OfferWidget`. None of this wiring exists yet beyond the Express app shell and a DB health check.
- **model-service** is a separate ML microservice, not a library imported by `api` — it's intended to own feature engineering (`model-service/features/`) and model code (`model-service/models/`) behind its own HTTP API. Both packages currently only contain empty `__init__.py` files.
- **db** owns schema evolution independently of `api`, via a small hand-rolled runner instead of an ORM/migration framework:
  - Numbered SQL files in `db/migrations/` (`NNN_description.sql`), applied once each in filename order, tracked in a `schema_migrations` table (see `db/migrate.js`, `db/migrations/README.md`).
  - Full-line `-- ` comments are stripped before splitting a file on `;`; once a file has been applied, don't edit it — add a new numbered file instead.
  - `db/migrate.js` loads its DB connection config from `api/.env`, not its own — `api/` is the single source of truth for `DB_HOST`/`DB_USER`/`DB_PASS`/`DB_NAME`/`DB_PORT`.
- **Env var flow**: the root `.env` feeds MySQL credentials (`MYSQL_ROOT_PASSWORD`/`MYSQL_DATABASE`/`MYSQL_USER`/`MYSQL_PASSWORD`) into the `mysql` service in `docker-compose.yml`. `api/.env` holds the client-side connection values that both `api/db/pool.js` and `db/migrate.js` read. `DB_HOST` is `127.0.0.1` when running `api`/`db` scripts on the host against the compose-mapped port, or `mysql` if `api` itself runs inside Docker Compose.
- `api/db/pool.js` exports a shared `mysql2` connection pool; `GET /health/db` on the Express app is the way to verify DB connectivity without writing domain queries.

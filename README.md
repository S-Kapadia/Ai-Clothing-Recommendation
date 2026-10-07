# AI Advert

AI-powered marketing recommendation plugin.

## Setup

1. Copy env files and fill in local values:
   ```
   cp .env.example .env
   cp api/.env.example api/.env
   ```
2. Install dependencies in `api/` and `db/`:
   ```
   cd api && npm install
   cd ../db && npm install
   ```

## Running Locally

1. Start MySQL: `docker compose up -d mysql`
2. Apply migrations: `cd db && npm run migrate` (see `db/migrations/README.md`)
3. Start the API: `cd api && npm start`
4. Check the DB connection: `curl localhost:3000/health/db`

## Tech Stack

- Frontend: React + TypeScript + Vite
- API: Node.js + Express
- Model service: Python + FastAPI
- Database: MySQL, with hand-written migrations in `db/migrations/`

# Architecture

## Overview

## Data Flow

Schema changes live in `db/migrations/` as numbered, hand-written SQL files (no ORM/framework). To change the schema: add a new `NNN_description.sql` file, then run `npm run migrate` from `db/`. Applied files are tracked in a `schema_migrations` table so re-running is safe. See `db/migrations/README.md` for the naming convention.

## API Contracts

## Model Approach

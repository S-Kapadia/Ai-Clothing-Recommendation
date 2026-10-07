# Migrations

Plain numbered SQL files, applied in order, tracked in a `schema_migrations` table. No framework.

## Convention

- Name files `NNN_description.sql` (e.g. `001_init.sql`, `002_add_offers.sql`), zero-padded, strictly increasing.
- One logical change per file. Once a file has been applied anywhere (including locally), don't edit it — add a new numbered file instead.
- Plain SQL only. Full-line `-- comments` are stripped before execution; statements are split on `;`.

## Running

From the `db/` directory (one-time `npm install` first):

```
npm install
npm run migrate
```

This creates `schema_migrations` if it doesn't exist yet, and applies any `.sql` file in this folder that isn't already recorded there, in filename order.

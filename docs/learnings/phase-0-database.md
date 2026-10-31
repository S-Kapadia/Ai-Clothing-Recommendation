# Phase 0 — database design choices

Every non-obvious call made while writing `supabase/migrations/0001_catalog.sql` and
`0002_accounts.sql`, with the alternative considered and what would make me revisit it.

## 0001_catalog.sql

**IDs: `uuid default gen_random_uuid()`.**
Alternatives: `bigserial`/identity columns. Why: matches §4 ("all ids are uuid unless
noted"); no cross-table sequence coordination. `gen_random_uuid()` is a core Postgres
13+ function, so no `pgcrypto` extension is needed (dropped it after first draft).
Would change if: needed sortable/sequential ids for pagination (uuidv7 or bigint).

**CHECK constraints instead of native enums.**
Alternative: `create type ... as enum`. Why: the attribute vocabulary is explicitly
flagged as not-yet-final (§12 open question); adding a value to a `text` CHECK is a
plain migration, adding one to a Postgres enum type is more awkward and can block on
other transactions. Would change if: vocab froze and the smaller enum storage/compare
cost actually mattered.

**`size_charts.source_type`: `'html_table' \| 'text' \| 'page' \| 'image'`.**
First draft guessed at *location* (`product_page`/`size_guide_page`); corrected to
*format*, since format is what actually drives rules-vs-LLM routing and stratifies the
gold-chart benchmark (§5 step 4, quantization benchmark). Would change if a brand's
chart doesn't fit one of the four cleanly (e.g. a PDF).

**`size_charts.basis`: `'body' \| 'garment'`.**
My reading of an ambiguous spec column: whether the chart's raw numbers are body or
garment measurements, since the fit formula (§6.2) assumes `g` is a garment
measurement. Flows into `variant_measurements` per row. Would change if a review of
real charts shows "basis" means something else (e.g. flat vs circumference) — then
rename/redefine, don't just relabel.

**`size_charts.method`: `'rules' \| 'llm'`** (not `'ollama_extract'`).
Changed to match `product_attributes.source`'s vocabulary — one word for the
rules-vs-model distinction everywhere in the schema, not two.

**`chart_measurements`/`gold_labels.dimension`: added `shoulder`, `rise`.**
§5 step 4.2 only names six dimensions; shoulder width and rise are common on real
shirt/pants charts and gold labels drawn from real charts will likely need them. Would
change if brands never report these two in practice (drop to shrink the vocab).

**ON DELETE: cascade down the catalog tree, `SET NULL` for `products.chart_id`,
`RESTRICT` for `gold_labels.chart_id` and `query_labels.product_id`.**
Brand deletion is rare/administrative, so cascading its whole catalog is expected and
fine. `products.chart_id → SET NULL` because a product shouldn't vanish just because
its chart got replaced — the variant mapper relinks it. `RESTRICT` on the two
hand-labelled tables protects labor-intensive labels from silent loss; Postgres refuses
the delete instead. Would change if routine recrawls regularly replace `products`/
`size_charts` rows wholesale — then `RESTRICT` would start blocking normal operations
and the tradeoff flips toward `CASCADE` plus accepted label churn.

**`extraction_runs` CHECK: exactly one of `chart_id`/`product_id`.**
Alternative: two plain nullable FKs with no constraint, or one polymorphic
`entity_id` + discriminator (loses FK-level integrity). The CHECK
`(chart_id is not null) <> (product_id is not null)` catches a logging bug (row
against neither or both) for free at insert time. Would change if a future stage needs
to log against both at once — rethink the shape, don't just loosen the check.

**Upsert keys: `variants` unique `(product_id, shopify_variant_id)`; `products` unique
`(brand_id, shopify_product_id)` kept alongside `(brand_id, handle)`.**
Shopify's numeric ids are the stable identity for re-crawl upserts (§5 "re-runs reuse
raw responses"); `handle` can be renamed by a brand, so it can't be the sole upsert
key, but it's still a valid uniqueness fact about *current* live products, so both
constraints stay.

**`product_attributes` dropped `category`/`department` columns.**
First draft duplicated them from `products`. `products.category`/`department` come
from classification (§5 step 2); `product_attributes` is the full 11-vocab extraction
(§5 step 6). Keeping both in two tables meant two sources of truth for the same two
columns — removed from `product_attributes`, `products` is now the only place they
live.

**`variant_measurements` view: `with (security_invoker = true)`.**
Without it, a view runs with its *owner's* privileges by default, which could let a
client read through to catalog tables regardless of their RLS (service-role-only)
policies. `security_invoker` makes the view re-evaluate RLS as the querying role
instead, so it can't become an accidental bypass.

**Dropped redundant indexes: `chart_measurements.chart_id`, `size_charts.brand_id`,
`gold_labels.chart_id`, `query_labels.query_id`.**
Each was a standalone index on a column that's already the *leading* column of a
unique constraint on the same table — Postgres already has an index that serves those
lookups, so the explicit one was dead weight.

**Flagged, not changed: `idx_variants_product_id` and `idx_products_brand_id` are now
also redundant** (the new upsert-key unique constraints above lead with those same
columns), but left in place since not explicitly asked — same redundant-index argument
applies if a later pass wants full consistency.

## 0002_accounts.sql

**`profiles` has its own `id`; `user_id` is nullable + unique, not the primary key.**
First draft made `user_id` itself the PK referencing `auth.users` directly — breaks for
personas, who need a profile row with no real login-capable account. Alternative
rejected: create a real-but-unusable shadow `auth.users` row per persona (via the admin
API) — works, but means permanently maintaining fake "login" accounts that must never
actually authenticate, a needless security footgun. Decoupling `id` from `user_id`
means personas simply have `user_id = null`; `owned_items`/`style_preferences` key off
`profiles.id`, and ownership RLS checks the row's `profiles.user_id = auth.uid()` via a
subquery. Would change if that subquery join becomes a measurable perf problem at
scale — then denormalize `user_id` onto the child tables with a sync trigger.

**`profiles` CHECK: `user_id is not null or is_persona`.**
Enforces "every row is either a real user or a persona, never neither" directly in the
schema rather than trusting the API to maintain it.

**`height_cm`, `weight_kg`, `department`, `display_name` left nullable.**
The signup trigger (below) inserts only `user_id`; every other column must be able to
take its default or `null` and still pass its CHECK. Postgres CHECKs already pass when
an operand is `null` (the expression evaluates to unknown, not false), so this falls
out naturally from *not* adding `not null` — no extra work, just restraint.

**Signup trigger (`handle_new_user`) auto-creates a profile row.**
Alternative rejected: lazy-create the profile on first `GET`/`PUT /v1/me/profile` from
the API. Rejected because it turns a one-time migration cost into a permanent extra
code path and a race condition (what does `GET` return before the first `PUT`?) that
the trigger makes structurally impossible. The trigger inserts only `user_id` — every
other column uses its default, which is exactly why those columns had to be nullable
or defaulted above.

**`security definer` on the trigger function.**
Required because the role performing the `auth.users` insert during signup has no
reason to hold `INSERT` on `public.profiles`, and even if it did, the normal owner RLS
policy (`user_id = auth.uid()`) can't apply yet — there's no session to compare
against mid-signup. `security definer` runs the function as its owner instead of the
caller, bypassing that chicken-and-egg problem.

**`set search_path = ''` on the trigger function (not `'public'`).**
First draft pinned `search_path = public`, which is already the standard advice over
leaving it unset — a `security definer` function with an unset/caller-controlled
search path is a classic privilege-escalation vector: anyone who can `create` an
object (table, function) in a schema that resolves earlier in *their* session's search
path can shadow a name the function relies on, and the function — running with the
owner's elevated privileges — would silently operate on the attacker's object. Setting
it to `''` goes further: no identifier resolves implicitly at all, forcing every
reference to be fully schema-qualified. Since the function body already writes
`public.profiles` explicitly, nothing is lost by closing the door all the way.

**RLS: owner `with check` also requires `is_persona = false` and `is_synthetic =
false`.**
Without this, a real signed-in user could `update` their *own* row (which the `using`
clause already permits, since `user_id = auth.uid()` matches) and simply set
`is_persona = true` on it — the plain ownership check never looks at that column.
Requiring both flags to be `false` in every client-written row closes that off; there
is deliberately no policy that lets a client set either flag to `true`, so persona
rows can only ever be created by the (service-role) pipeline.

**`owned_items`/`style_preferences` don't need the same `is_persona` guard.**
Those tables have no `is_persona` column of their own to flip. Their owner policy
already requires the row's `profiles.user_id = auth.uid()` via a subquery, and a
persona's profile has `user_id = null`, which never equals a real `auth.uid()` — so
writes against persona-owned rows are blocked by the existing join, not by an extra
clause.

**`(select auth.uid())` instead of bare `auth.uid()` in every policy.**
Wrapping the call lets Postgres evaluate it once per query (as an initPlan) instead of
re-evaluating it for every row the policy is checked against — a standard Supabase
performance recommendation. Doesn't change which rows match, only how many times the
function runs.

**`style_preferences.value` has no CHECK against its attribute's specific vocabulary.**
Each of the 11 attributes allows a different set of values, which a static CHECK can't
express (would need a trigger that looks up `attribute` and branches). Deferred to the
API's Pydantic validation instead. Would change if a bad value is ever written by
something that bypasses the API (a script using the service role) and corrupts style
scoring — then the trigger becomes worth the complexity.

**No separate index on `style_preferences.profile_id`.**
Same lesson as the `0001` redundant-index cleanup, applied proactively this time: the
`unique(profile_id, attribute, value)` constraint already indexes `profile_id` as its
leading column.

## Schema smoke tests (`tests/conftest.py`, `tests/integration/test_schema.py`)

**The `conftest.py` fixtures, and why they live at `tests/` not `tests/integration/`.**
Two fixtures: `db_connection` (session-scoped) opens one `psycopg` connection to
`DATABASE_URL` for the entire test run and closes it once, at the very end, when the
session fixture tears down. `db_cursor` (function-scoped, the default) opens a fresh
cursor *per test*, and on teardown closes the cursor and rolls back the connection.
Scoping matters here: re-opening a Postgres connection for every test is wasteful
("setup" cost paid once per test instead of once per run), but if two tests shared a
cursor with no rollback between them, a test that wrote a row could leak into the next
test's result set. The rollback after each test is a no-op for these two read-only
smoke tests, but it's what makes the fixture safe to reuse once a test *does* write
(e.g. a future RLS test that inserts a row as one user and tries to read it as
another). Living at `tests/conftest.py` rather than inside `tests/integration/` is what
lets `tests/unit/` pick up the same fixtures later without duplicating them —
pytest applies a `conftest.py` to every test file at or below its directory.

**Which catalog tables each test queries, and what the columns mean.**
- `information_schema.tables` (`test_catalog_and_account_tables_exist`): the
  SQL-standard, cross-database view of every table/view in the database.
  `table_schema = 'public'` scopes it to our schema (excludes Postgres internals and
  `auth.*`); `table_type = 'BASE TABLE'` excludes views, which is why
  `variant_measurements` has to be checked separately.
- `information_schema.views` (`test_variant_measurements_view_exists`): the same idea,
  but the standard view listing *views* instead of tables — there's no `table_type`
  filter needed since this view only ever lists views.
- `pg_class` joined to `pg_namespace` (`test_rls_enabled_and_signup_trigger_exists`):
  Postgres-specific catalogs, not the SQL-standard `information_schema` ones, because
  RLS has no standard-SQL representation. `pg_namespace.nspname = 'public'` is the
  schema filter (same role as `table_schema` above, different catalog);
  `relkind = 'r'` means "ordinary table" (as opposed to `'v'` for view, `'i'` for
  index); `relrowsecurity` is the boolean the whole test hinges on — `enable row level
  security` is literally just this flag.
- `pg_trigger` (same test): one row per trigger in the database. `tgname` is the
  trigger's name as given in `create trigger`; `tgrelid` is the oid of the table it's
  attached to, cast for comparison via `'auth.users'::regclass`, which resolves a
  table name to the oid `tgrelid` actually stores.

**Why the smoke test checks RLS and the trigger, not just that tables exist.**
"The tables exist" only proves the `CREATE TABLE` statements ran — it says nothing
about whether the *security* behavior we spent two migrations designing is actually
switched on. `0001`/`0002`'s whole point was RLS policies and the signup trigger; a
typo that silently dropped an `alter table ... enable row level security` line, or a
migration that got reordered so the trigger never got created, would leave every table
present and every later test (API integration tests, manual testing) potentially
reading data through a security hole that only shows up under a cross-user scenario
nobody happened to test yet. Checking `relrowsecurity` and `pg_trigger` directly here
catches that class of bug at the cheapest possible point — right after
`supabase db reset` — instead of discovering it later via a failing (or worse,
silently passing) auth test.

**Running a single test, and what a failure looks like.**
`pytest tests/integration/test_schema.py::test_rls_enabled_and_signup_trigger_exists
-v` runs just that one test (module path, `::`, test function name). A failure shows
up as a normal pytest `AssertionError` with the message string from the `assert`
— e.g. `AssertionError: RLS not enabled on: {'profiles'}` if someone's migration
edit ever removed that `alter table` line, or `AssertionError: signup trigger
on_auth_user_created is missing` if the trigger got dropped or renamed — plus pytest's
usual traceback pointing at the exact `assert` line. If the database itself is down or
`DATABASE_URL` is wrong, you'd instead see a connection error during fixture setup,
reported as an **error**, not a failure — pytest distinguishes "the test's assertion
was false" from "the test never got to run."

## Session wrap-up

A few choices from this session that weren't captured above:

**Postgres driver: `psycopg` (v3), not `psycopg2`.**
Your `.venv` already had `psycopg` installed and not `psycopg2`, so `tests/conftest.py`
uses that rather than adding a second driver family for no reason. Would change if the
rest of the project (e.g. a future ORM or the FastAPI service) standardizes on
`psycopg2` for some other reason — stay on one driver, don't mix.

**`requirements.txt` scope: only what the Phase 0 tests need.**
`pytest`, `psycopg[binary]`, `python-dotenv` — nothing from later phases (no FAISS,
LightGBM, Ollama client, etc.). Keeping it scoped to "what currently-committed code
actually imports" means it stays a true record of dependencies instead of a wishlist;
each later phase adds its own as it's written.

**`.env` parsing incident, for the record.**
`supabase db reset` failed with a bare `DbConfigLoadError` before it ever touched a
migration — the cause was a stray value-only line in `.env` (no `KEY=` name, likely a
pasted credential fragment). Worth remembering as the first thing to check if
`supabase start`/`db reset` ever fails with that error again: it's an `.env` parsing
problem, not a migration problem, and the error message doesn't say so.

**`tests/integration/test_rls.py` left uncommitted this session.**
It exists on disk but is empty — you're actively writing it (single transaction,
`SET LOCAL ROLE authenticated` + `request.jwt.claims` to impersonate users, positive
control for user A, zero rows for user B, rollback to clean up). Committing an empty
placeholder now would just be noise in the history; it's yours to commit once it has a
real test body.

## Comprehension questions

1. If a product's size chart gets re-parsed into a new `size_charts` row, what happens
   to that product's `chart_id`, and what happens to any `variants` whose
   `chart_size_label` no longer matches a label in the new chart?
2. Why can a persona's `profiles` row exist with `user_id = null`, and what would break
   if every persona instead got a real (but unusable) row in `auth.users`?
3. Walk through `variant_measurements` for one variant: which tables does the view
   touch, and on which two columns does it join `chart_measurements`?
4. You delete a `size_charts` row that has `gold_labels` pointing at it. What happens,
   and why was that the deliberate choice instead of `CASCADE`?
5. A `style_preferences` row has `attribute = 'fabric'`, `value = 'cotton'`. What in
   the schema stops someone inserting `attribute = 'fabric'`, `value = 'xyz123'` — and
   what does *not* stop them?
6. A logged-in user runs `UPDATE profiles SET is_persona = true WHERE user_id =
   auth.uid()`. What specifically stops this from succeeding?
7. An anonymous (not logged-in) visitor queries `owned_items` directly through the
   client. Under what condition, if any, do they get rows back, and which policy
   allows it?
8. Wrapping `auth.uid()` as `(select auth.uid())` in a policy changes performance but
   not which rows are returned. What's actually happening differently at execution
   time?
9. `test_catalog_and_account_tables_exist` filters on `table_type = 'BASE TABLE'`, but
   `test_variant_measurements_view_exists` queries a different `information_schema`
   view entirely instead of just dropping that filter. Why can't one query with a
   different `table_type` value cover both tables and views?
10. If someone's migration edit accidentally dropped the `alter table profiles enable
    row level security` line, which of the three smoke tests would fail, and which
    would still pass without noticing anything wrong?

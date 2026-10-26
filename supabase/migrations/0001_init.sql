-- Phase 0: core catalog, measurement, labelling and logging tables (HLD §5).
-- Measurements are stored as rows (chart/size/dimension -> value_cm) rather than
-- columns, so new categories only need new dimension names, never a schema change.

create table stores (
    id uuid primary key default gen_random_uuid(),
    domain text not null unique,
    name text not null,
    snapshot_date date,
    vetting_notes text,
    created_at timestamptz not null default now()
);

create table size_charts (
    id uuid primary key default gen_random_uuid(),
    content_fingerprint text not null unique,
    source_type text not null check (source_type in ('html_table', 'text', 'page', 'image')),
    status text not null check (status in ('parsed', 'abstained')),
    method text check (method in ('rules', 'llm')),
    confidence numeric,
    basis text check (basis in ('garment', 'body')),
    review_flags jsonb not null default '[]'::jsonb,
    abstain_reason text,
    created_at timestamptz not null default now()
);

create table products (
    id uuid primary key default gen_random_uuid(),
    store_id uuid not null references stores (id) on delete cascade,
    shopify_product_id text not null,
    handle text not null,
    title text not null,
    category text check (category in ('tshirt', 'shirt', 'pants', 'shorts', 'other')),
    department text check (department in ('men', 'women', 'unisex')),
    product_type text,
    tags jsonb not null default '[]'::jsonb,
    description_text text,
    product_url text not null,
    image_urls jsonb not null default '[]'::jsonb,
    chart_id uuid references size_charts (id) on delete set null,
    created_at timestamptz not null default now(),
    unique (store_id, shopify_product_id),
    unique (store_id, handle)
);

create table variants (
    id uuid primary key default gen_random_uuid(),
    product_id uuid not null references products (id) on delete cascade,
    shopify_variant_id text not null,
    size_label text not null,
    chart_size_label text,
    price numeric,
    available boolean not null default true,
    created_at timestamptz not null default now(),
    unique (product_id, shopify_variant_id)
);

create table chart_measurements (
    id uuid primary key default gen_random_uuid(),
    chart_id uuid not null references size_charts (id) on delete cascade,
    size_label text not null,
    dimension text not null,
    value_cm numeric not null,
    created_at timestamptz not null default now(),
    unique (chart_id, size_label, dimension)
);

-- One row per (variant, dimension): the variant's own size resolved against its
-- product's chart, via the variant mapper's chart_size_label (not the raw Shopify
-- size_label, which may not match the chart's own labels verbatim, e.g. "32x30" vs
-- a chart row keyed "32"). Empty until Phase 1 (crawl), Phase 2 (chart parsing) and
-- the variant mapper populate products/variants/chart_measurements.
create view variant_measurements as
select
    v.id as variant_id,
    cm.dimension,
    cm.value_cm,
    sc.basis
from variants v
join products p on p.id = v.product_id
join chart_measurements cm
    on cm.chart_id = p.chart_id
    and cm.size_label = v.chart_size_label
join size_charts sc on sc.id = p.chart_id;

create table extraction_runs (
    id uuid primary key default gen_random_uuid(),
    chart_id uuid not null references size_charts (id) on delete cascade,
    model_name text not null,
    prompt_version text not null,
    stage text not null check (stage in ('extract', 'review')),
    input_hash text not null,
    raw_output jsonb not null,
    latency_ms integer,
    created_at timestamptz not null default now()
);

create table gold_labels (
    id uuid primary key default gen_random_uuid(),
    chart_id uuid not null references size_charts (id) on delete cascade,
    size_label text not null,
    dimension text not null,
    value_cm numeric not null,
    created_at timestamptz not null default now(),
    unique (chart_id, size_label, dimension)
);

create table closet_items (
    id uuid primary key default gen_random_uuid(),
    owner_alias text not null,
    owner_height_cm numeric not null,
    owner_weight_kg numeric not null,
    brand text not null,
    item_name text not null,
    size_label text not null,
    category text not null check (category in ('tshirt', 'shirt', 'pants', 'shorts', 'other')),
    garment_measurements jsonb not null,
    fit_words jsonb not null,
    overall_verdict text check (overall_verdict in ('wear', 'wear_but_flawed', 'dont_wear')),
    variant_id uuid references variants (id) on delete set null,
    created_at timestamptz not null default now()
);

-- Timings/result-count only. Never a column for height, weight, query text, URLs,
-- purchases, clicks or ratings (CLAUDE.md: no server-side storage of shopper data).
create table request_log (
    id uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    step_timings jsonb not null default '{}'::jsonb,
    result_count integer
);

-- RLS on every table; no policies, since only the service role key (which bypasses
-- RLS) is used by the pipeline/server. `variant_measurements` is a view, not a
-- table, so RLS doesn't apply to it directly -- it inherits the underlying tables'
-- access via the querying role's own grants.
alter table stores enable row level security;
alter table size_charts enable row level security;
alter table products enable row level security;
alter table variants enable row level security;
alter table chart_measurements enable row level security;
alter table extraction_runs enable row level security;
alter table gold_labels enable row level security;
alter table closet_items enable row level security;
alter table request_log enable row level security;

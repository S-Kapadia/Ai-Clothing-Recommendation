-- Phase 0: catalog, sizing, attribute and label tables (docs/DESIGN.md section 4).
-- gen_random_uuid() is a core Postgres 13+ function; no extension needed.

create table brands (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  domain text not null unique,
  snapshot_date date,
  notes text,
  created_at timestamptz not null default now()
);

create table size_charts (
  id uuid primary key default gen_random_uuid(),
  brand_id uuid not null references brands(id) on delete cascade,
  content_fingerprint text not null,
  source_type text not null check (source_type in ('html_table', 'text', 'page', 'image')),
  status text not null check (status in ('parsed', 'abstained')),
  method text not null check (method in ('rules', 'llm')),
  confidence numeric check (confidence between 0 and 1),
  basis text check (basis in ('body', 'garment')),
  review_flags jsonb not null default '[]'::jsonb,
  abstain_reason text,
  created_at timestamptz not null default now(),
  unique (brand_id, content_fingerprint)
);
-- No separate index on brand_id: the unique constraint above already indexes it
-- as the leading column, so a standalone index would be redundant.

create table products (
  id uuid primary key default gen_random_uuid(),
  brand_id uuid not null references brands(id) on delete cascade,
  shopify_product_id bigint not null,
  handle text not null,
  title text not null,
  product_type text,
  tags jsonb not null default '[]'::jsonb,
  description_text text,
  category text check (category in ('tshirt', 'shirt', 'pants', 'shorts', 'other')),
  department text check (department in ('men', 'women', 'unisex')),
  product_url text,
  image_urls jsonb not null default '[]'::jsonb,
  chart_id uuid references size_charts(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (brand_id, handle),
  unique (brand_id, shopify_product_id)
);
create index idx_products_brand_id on products (brand_id);
create index idx_products_chart_id on products (chart_id);

create table variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  shopify_variant_id bigint not null,
  size_label text not null,
  chart_size_label text,
  price numeric(10, 2),
  available boolean not null default true,
  created_at timestamptz not null default now(),
  unique (product_id, shopify_variant_id)
);
create index idx_variants_product_id on variants (product_id);
create index idx_variants_chart_size_label on variants (chart_size_label);

create table chart_measurements (
  id uuid primary key default gen_random_uuid(),
  chart_id uuid not null references size_charts(id) on delete cascade,
  size_label text not null,
  dimension text not null check (
    dimension in ('chest', 'body_length', 'sleeve', 'waist', 'hip', 'inseam', 'shoulder', 'rise')
  ),
  value_cm numeric not null,
  created_at timestamptz not null default now(),
  unique (chart_id, size_label, dimension)
);
-- No separate index on chart_id: the unique constraint above already indexes it
-- as the leading column, so a standalone index would be redundant.

-- variant_measurements: derived per variant, not stored, so a re-parsed chart
-- can never drift out of sync with what a variant reports.
-- security_invoker = true: the view runs under the querying role's own
-- permissions, so RLS on the underlying tables is evaluated for that role
-- instead of the view owner's -- without it, a client could bypass the
-- catalog tables' service-role-only policies by querying the view directly.
create view variant_measurements with (security_invoker = true) as
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

create table product_attributes (
  product_id uuid primary key references products(id) on delete cascade,
  fit_type text check (fit_type in ('slim', 'regular', 'relaxed', 'oversized')),
  colour_family text check (
    colour_family in (
      'black', 'white', 'grey', 'navy', 'blue', 'green',
      'brown_beige', 'red_pink', 'yellow_orange', 'multi'
    )
  ),
  pattern text check (pattern in ('solid', 'striped', 'checked', 'graphic', 'printed', 'other')),
  fabric text check (fabric in ('cotton', 'linen', 'denim', 'wool', 'synthetic', 'blend')),
  stretch boolean,
  neckline_collar text check (
    neckline_collar in ('crew', 'v_neck', 'polo', 'button_down', 'spread', 'none')
  ),
  sleeve_length text check (sleeve_length in ('short', 'long', 'none')),
  leg_shape text check (leg_shape in ('skinny', 'slim', 'straight', 'wide', 'none')),
  formality text check (formality in ('casual', 'smart_casual', 'formal')),
  source text not null check (source in ('rules', 'llm')),
  model text,
  prompt_version text,
  confidence numeric check (confidence between 0 and 1),
  created_at timestamptz not null default now()
);

create table gold_labels (
  id uuid primary key default gen_random_uuid(),
  chart_id uuid not null references size_charts(id) on delete restrict,
  size_label text not null,
  dimension text not null check (
    dimension in ('chest', 'body_length', 'sleeve', 'waist', 'hip', 'inseam', 'shoulder', 'rise')
  ),
  value_cm numeric not null,
  created_at timestamptz not null default now(),
  unique (chart_id, size_label, dimension)
);
-- No separate index on chart_id: redundant with the unique constraint above.

create table query_labels (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null,
  query_text text not null,
  product_id uuid not null references products(id) on delete restrict,
  grade smallint not null check (grade in (0, 1, 2)),
  labeller text not null,
  created_at timestamptz not null default now(),
  unique (query_id, product_id)
);
-- No separate index on query_id: redundant with the unique constraint above,
-- which already indexes it as the leading column. product_id still needs its
-- own index since it's the second column and not covered as a lookup prefix.
create index idx_query_labels_product_id on query_labels (product_id);

create table extraction_runs (
  id uuid primary key default gen_random_uuid(),
  chart_id uuid references size_charts(id) on delete cascade,
  product_id uuid references products(id) on delete cascade,
  stage text not null check (stage in ('extract', 'review', 'attributes')),
  model text not null,
  prompt_version text not null,
  input_hash text not null,
  raw_output jsonb not null,
  latency_ms integer,
  created_at timestamptz not null default now(),
  check ((chart_id is not null) <> (product_id is not null))
);
create index idx_extraction_runs_chart_id on extraction_runs (chart_id);
create index idx_extraction_runs_product_id on extraction_runs (product_id);

create table request_log (
  id uuid primary key default gen_random_uuid(),
  endpoint text not null,
  status_code integer not null,
  step_timings jsonb,
  result_count integer,
  created_at timestamptz not null default now()
);

-- RLS on every table; no client policies here -- service role only (docs/DESIGN.md section 4).
alter table brands enable row level security;
alter table size_charts enable row level security;
alter table products enable row level security;
alter table variants enable row level security;
alter table chart_measurements enable row level security;
alter table product_attributes enable row level security;
alter table gold_labels enable row level security;
alter table query_labels enable row level security;
alter table extraction_runs enable row level security;
alter table request_log enable row level security;

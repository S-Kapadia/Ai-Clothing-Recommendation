-- Phase 0: accounts and style tables, with RLS (docs/DESIGN.md section 4).

create table profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete cascade,
  display_name text,
  height_cm numeric check (height_cm between 140 and 220),
  weight_kg numeric check (weight_kg between 40 and 200),
  department text check (department in ('men', 'women', 'unisex')),
  style_weight numeric not null default 0.5 check (style_weight between 0 and 1),
  is_persona boolean not null default false,
  is_synthetic boolean not null default false,
  created_at timestamptz not null default now(),
  check (user_id is not null or is_persona)
);

create table owned_items (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  variant_id uuid references variants(id) on delete set null,
  brand_text text,
  item_text text,
  category text check (category in ('tshirt', 'shirt', 'pants', 'shorts', 'other')),
  size_label text,
  fit_words jsonb not null default '{}'::jsonb,
  verdict text check (verdict in ('wear', 'wear_but_flawed', 'dont_wear')),
  created_at timestamptz not null default now()
);
create index idx_owned_items_profile_id on owned_items (profile_id);
create index idx_owned_items_variant_id on owned_items (variant_id);

create table style_preferences (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  attribute text not null check (
    attribute in (
      'category', 'department', 'fit_type', 'colour_family', 'pattern', 'fabric',
      'stretch', 'neckline_collar', 'sleeve_length', 'leg_shape', 'formality'
    )
  ),
  value text not null,
  weight numeric not null check (weight between -1 and 1),
  created_at timestamptz not null default now(),
  unique (profile_id, attribute, value)
);
-- No separate index on profile_id: the unique constraint above already indexes
-- it as the leading column.

-- Auto-create a profile on signup so every real user has exactly one profile
-- row immediately, with no lazy-create race in the API. security definer runs
-- this with the function owner's privileges (needed to insert past profiles'
-- RLS, since there is no session yet to satisfy the owner policy at signup
-- time); search_path is set to empty, not just pinned to 'public', so no
-- identifier resolves implicitly at all -- the insert below is already fully
-- schema-qualified, so nothing is lost.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();

alter table profiles enable row level security;
alter table owned_items enable row level security;
alter table style_preferences enable row level security;

-- (select auth.uid()) rather than auth.uid(): wrapping it in a select lets
-- Postgres evaluate it once per query (an initPlan) instead of once per row.

create policy "own profile" on profiles
  for all
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and is_persona = false
    and is_synthetic = false
  );

create policy "persona profiles readable" on profiles
  for select
  using (is_persona = true);

create policy "own owned_items" on owned_items
  for all
  using (
    exists (
      select 1 from profiles p
      where p.id = owned_items.profile_id and p.user_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1 from profiles p
      where p.id = owned_items.profile_id and p.user_id = (select auth.uid())
    )
  );

create policy "persona owned_items readable" on owned_items
  for select
  using (
    exists (
      select 1 from profiles p
      where p.id = owned_items.profile_id and p.is_persona
    )
  );

create policy "own style_preferences" on style_preferences
  for all
  using (
    exists (
      select 1 from profiles p
      where p.id = style_preferences.profile_id and p.user_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1 from profiles p
      where p.id = style_preferences.profile_id and p.user_id = (select auth.uid())
    )
  );

create policy "persona style_preferences readable" on style_preferences
  for select
  using (
    exists (
      select 1 from profiles p
      where p.id = style_preferences.profile_id and p.is_persona
    )
  );

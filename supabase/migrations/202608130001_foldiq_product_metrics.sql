create table if not exists public.product_events (
  event_id uuid primary key,
  install_hash text not null check (length(install_hash) = 64),
  event_name text not null check (event_name in ('scan_completed', 'apply_completed', 'undo_completed')),
  platform text not null check (platform in ('macos', 'windows')),
  app_version text not null check (length(app_version) between 5 and 24),
  success boolean not null,
  duration_bucket text not null check (duration_bucket in ('under_30s', '30s_2m', '2m_5m', '5m_15m', 'over_15m')),
  item_count_bucket text not null check (item_count_bucket in ('0', '1_49', '50_199', '200_999', '1000_4999', '5000_plus')),
  created_at timestamptz not null default now()
);

alter table public.product_events enable row level security;
revoke all on table public.product_events from anon, authenticated;
create index if not exists product_events_created_at_idx on public.product_events (created_at desc);
create index if not exists product_events_install_date_idx on public.product_events (install_hash, created_at desc);

create or replace function public.delete_expired_product_events()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.product_events where created_at < now() - interval '90 days';
$$;

revoke all on function public.delete_expired_product_events() from public, anon, authenticated;

create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule(
  'foldiq-delete-expired-product-events',
  '17 3 * * *',
  $$select public.delete_expired_product_events();$$
);

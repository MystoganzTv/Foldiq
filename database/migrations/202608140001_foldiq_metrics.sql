create table if not exists product_events (
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

create index if not exists product_events_created_at_idx on product_events (created_at desc);
create index if not exists product_events_install_date_idx on product_events (install_hash, created_at desc);

create table if not exists apple_analytics_rows (
  report_name text not null,
  event_date date not null,
  dimension_hash text not null check (length(dimension_hash) = 64),
  dimensions jsonb not null default '{}'::jsonb,
  metrics jsonb not null default '{}'::jsonb,
  processing_date date not null,
  source_instance_id text not null,
  updated_at timestamptz not null default now(),
  primary key (report_name, event_date, dimension_hash)
);

create index if not exists apple_analytics_rows_event_date_idx on apple_analytics_rows (event_date desc);
create index if not exists apple_analytics_rows_processing_date_idx on apple_analytics_rows (processing_date desc);

create table if not exists apple_analytics_imports (
  instance_id text primary key,
  report_name text not null,
  processing_date date not null,
  row_count integer not null check (row_count >= 0),
  imported_at timestamptz not null default now()
);

create index if not exists apple_analytics_imports_processing_date_idx on apple_analytics_imports (processing_date desc);

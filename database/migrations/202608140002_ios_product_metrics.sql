alter table product_events
  drop constraint if exists product_events_platform_check;

alter table product_events
  add constraint product_events_platform_check
  check (platform in ('ios', 'macos', 'windows'));

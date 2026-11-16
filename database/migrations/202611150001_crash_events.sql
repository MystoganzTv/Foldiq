-- Allow the anonymous, opt-in crash ping sent by the Windows app (1.0.22+).
-- It carries no error text, stack or paths: only that a crash happened, the app
-- version, and how long the app had been open (duration_bucket).
alter table product_events
  drop constraint if exists product_events_event_name_check;

alter table product_events
  add constraint product_events_event_name_check
  check (event_name in ('scan_completed', 'apply_completed', 'undo_completed', 'app_crashed'));

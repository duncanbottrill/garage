-- Adds exponential-backoff tracking for failed Tesla refresh-token rotations:
-- refresh_failures counts consecutive failures, next_refresh_at holds a due
-- row back from the sweep until the backoff window has passed.
alter table tesla_credentials
  add column refresh_failures int not null default 0,
  add column next_refresh_at timestamptz;

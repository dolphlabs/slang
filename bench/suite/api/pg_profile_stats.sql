-- Snapshot these rows before and after one route-only profile sample.
-- Enable pg_stat_statements in shared_preload_libraries and create its
-- extension in the benchmark database first; this diagnostic is not part of
-- the standard benchmark run.
SELECT queryid, calls, rows, total_exec_time, mean_exec_time, query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND (
    query LIKE 'SELECT id, email, name, country, to_char(created_at AT TIME ZONE%'
    OR query LIKE 'SELECT id, sku, qty, price_cents, status, to_char(created_at AT TIME ZONE%'
    OR query LIKE 'SELECT status, count(*), coalesce(sum(qty * price_cents), 0) FROM orders%'
    OR query LIKE 'INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at)%'
  )
ORDER BY queryid;

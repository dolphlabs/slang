-- Deterministic seed: every value is a function of the row id, so two
-- hosts seeded with the same scale hold identical data.
--   psql -v users=1000000 -v orders=20000000 -f seed.sql
\set ON_ERROR_STOP on
\timing on

INSERT INTO users (id, email, name, country, created_at)
SELECT g,
       'user' || g || '@example.com',
       'User ' || g,
       (ARRAY['US','CA','MX','BR','AR','UK','DE','FR','ES','IT',
              'NL','SE','PL','NG','ZA','EG','IN','JP','KR','AU'])[1 + (g * 7919) % 20],
       timestamptz '2020-01-01 00:00:00+00' + make_interval(secs => (g * 37) % (5 * 365 * 86400))
FROM generate_series(1::bigint, :users) AS g;

INSERT INTO orders (id, user_id, sku, qty, price_cents, status, created_at)
SELECT g,
       1 + (g * 2654435761) % :users,
       'SKU-' || lpad(((g * 40503) % 100000)::text, 5, '0'),
       1 + (g * 13) % 10,
       100 + (g * 7907) % 99900,
       (ARRAY['pending','paid','shipped','delivered','cancelled'])[1 + (g * 31) % 5],
       timestamptz '2021-01-01 00:00:00+00' + make_interval(secs => (g * 113) % (3 * 365 * 86400))
FROM generate_series(1::bigint, :orders) AS g;

SELECT setval(pg_get_serial_sequence('orders', 'id'), :orders);

CREATE INDEX orders_user_created ON orders (user_id, created_at DESC, id DESC);
ANALYZE users;
ANALYZE orders;

-- remembered for reset.sql
CREATE TABLE IF NOT EXISTS bench_meta (k text PRIMARY KEY, v bigint NOT NULL);
INSERT INTO bench_meta VALUES ('users', :users), ('orders', :orders)
ON CONFLICT (k) DO UPDATE SET v = excluded.v;

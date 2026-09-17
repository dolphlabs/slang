-- Between rounds: remove what POST /api/orders wrote, so every round
-- starts from the seeded table.
\set ON_ERROR_STOP on
DELETE FROM orders WHERE id > (SELECT v FROM bench_meta WHERE k = 'orders');
SELECT setval(pg_get_serial_sequence('orders', 'id'),
              (SELECT v FROM bench_meta WHERE k = 'orders'));
VACUUM (ANALYZE) orders;

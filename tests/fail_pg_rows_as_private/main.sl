import "pg";
struct Item { id: int }
fn bad(rows: pg.Rows) -> result[[Item], str] {
    return __pg_rows_as(rows);
}

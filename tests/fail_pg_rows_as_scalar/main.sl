import "pg";
fn bad(rows: pg.Rows) -> result[[int], str] {
    return pg.rows_as(rows);
}

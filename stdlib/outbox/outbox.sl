// The transactional outbox: write an event in the same database
// transaction as the change it describes, and let a relay publish it
// afterwards. The event is published if and only if the change commits --
// no lost events when the broker is down, no phantom events when the
// transaction rolls back.
//
//     import "outbox";
//
//     pg.exec(conn, outbox.schema(), deadline);          // once, in a migration
//
//     // in the request, inside the business transaction:
//     pg.exec(conn, "BEGIN", deadline);
//     ... the change ...
//     outbox.add(conn, "orders.created", payload, deadline);
//     pg.exec(conn, "COMMIT", deadline);
//
//     // in a relay task, in a loop:
//     let n = outbox.relay(conn, 100, publish_to_kafka, deadline);
//
// relay claims a batch with FOR UPDATE SKIP LOCKED, so any number of relays
// share the table without sending a row twice at the same time; a row is
// deleted once publish says it went out, and one whose publish failed is
// retried later, with backoff. Publishing is at-least-once (a relay can
// die after publishing and before deleting): consumers should be
// idempotent, for instance keyed on the event's id.

import "pg";

pub fn schema() -> str {
    return "CREATE TABLE IF NOT EXISTS outbox (" +
           "id BIGSERIAL PRIMARY KEY, topic TEXT NOT NULL, payload BYTEA NOT NULL, " +
           "attempts INT NOT NULL DEFAULT 0, " +
           "available_at TIMESTAMPTZ NOT NULL DEFAULT now(), " +
           "created_at TIMESTAMPTZ NOT NULL DEFAULT now()); " +
           "CREATE INDEX IF NOT EXISTS outbox_ready ON outbox (available_at, id)";
}

// Queues an event; call it inside the transaction that makes the change.
// Returns the event's id.
pub fn add(c: pg.Conn, topic: str, payload: bytes, deadline: until) -> result[int, str] {
    let rr = pg.query(c, "INSERT INTO outbox (topic, payload) VALUES ($1, $2) RETURNING id",
                      [pg.arg_text(topic), pg.arg_bytes(payload)], deadline);
    guard let rows = rr else let e = err_of(rr) { return err("outbox: " + e); }
    return ok(pg.get_int(rows, 0, 0));
}

pub struct Message {
    id: int,
    topic: str,
    payload: bytes,
    attempts: int,
}

// Publishes up to batch ready events with publish (true: it went out),
// deleting those that did and pushing back those that did not (by 2^attempts
// seconds, at most an hour). Returns how many were published. Uses its own
// transaction: call it on a connection that is not in one.
pub fn relay(c: pg.Conn, batch: int, publish: fn(Message) -> bool, deadline: until)
            -> result[int, str] {
    if pg.in_transaction(c) { return err("outbox: relay needs a connection outside a transaction"); }
    let br = pg.exec(c, "BEGIN", deadline);
    guard let _b = br else let be = err_of(br) { return err("outbox: " + be); }
    let qr = pg.query(c, "SELECT id, topic, payload, attempts FROM outbox WHERE available_at <= now() " +
                         "ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED",
                      [pg.arg_int(batch)], deadline);
    guard let rows = qr else let qe = err_of(qr) {
        let _r = pg.exec(c, "ROLLBACK", deadline);
        return err("outbox: " + qe);
    }
    let sent = 0;
    for i in 0..rows.count {
        let m = Message { id: pg.get_int(rows, i, 0), topic: pg.get_text(rows, i, 1),
                          payload: pg.get_bytes(rows, i, 2), attempts: pg.get_int(rows, i, 3) };
        let sql = "UPDATE outbox SET attempts = attempts + 1, available_at = now() + " +
                  "make_interval(secs => LEAST(3600, power(2, attempts + 1))) WHERE id = $1";
        if publish(m) {
            sql = "DELETE FROM outbox WHERE id = $1";
            sent = sent + 1;
        }
        let ur = pg.query(c, sql, [pg.arg_int(m.id)], deadline);
        guard let _u = ur else let ue = err_of(ur) {
            let _r = pg.exec(c, "ROLLBACK", deadline);
            return err("outbox: " + ue);
        }
    }
    let cr = pg.exec(c, "COMMIT", deadline);
    guard let _c = cr else let ce = err_of(cr) { return err("outbox: " + ce); }
    return ok(sent);
}

// Events waiting, ready or not.
pub fn pending(c: pg.Conn, deadline: until) -> result[int, str] {
    let rr = pg.query(c, "SELECT count(*) FROM outbox", [], deadline);
    guard let rows = rr else let e = err_of(rr) { return err("outbox: " + e); }
    return ok(pg.get_int(rows, 0, 0));
}

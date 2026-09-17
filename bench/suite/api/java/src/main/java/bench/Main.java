// heavy/api in Java: Vert.x 4 core HTTP server + reactive vertx-pg-client,
// one verticle per core. See bench/SPEC.md.
package bench;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.DeploymentOptions;
import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.http.HttpServerOptions;
import io.vertx.core.http.HttpServerRequest;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.pgclient.PgBuilder;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.PoolOptions;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

import java.util.Map;

public class Main extends AbstractVerticle {
    static final String TS = "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')";
    static final String SQL_USER = "SELECT id, email, name, country, " + TS + " FROM users WHERE id = $1";
    static final String SQL_ORDERS = "SELECT id, sku, qty, price_cents, status, " + TS
            + " FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2";
    static final String SQL_SUMMARY = "SELECT status, count(*), coalesce(sum(qty * price_cents), 0) FROM orders WHERE user_id = $1 GROUP BY status";
    static final String SQL_INSERT = "INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id";

    static final Map<String, Long> RATES = Map.ofEntries(
            Map.entry("US", 725L), Map.entry("CA", 1300L), Map.entry("UK", 2000L), Map.entry("EU", 2000L),
            Map.entry("DE", 1900L), Map.entry("FR", 2000L), Map.entry("JP", 1000L), Map.entry("IN", 1800L),
            Map.entry("BR", 1700L), Map.entry("NG", 750L), Map.entry("AU", 1000L));

    static final Buffer BAD = Buffer.buffer("{\"error\":\"bad request\"}");
    static final Buffer NOT_FOUND = Buffer.buffer("{\"error\":\"not found\"}");
    static final Buffer INTERNAL = Buffer.buffer("{\"error\":\"internal\"}");
    static final Buffer HEALTH = Buffer.buffer("{\"ok\":true}");

    static volatile Pool pool;

    static void fail(HttpServerRequest req, Throwable e) {
        if (System.getenv("BENCH_DEBUG") != null) e.printStackTrace();
        send(req, 500, INTERNAL);
    }

    static void send(HttpServerRequest req, int status, Buffer body) {
        req.response().setStatusCode(status)
                .putHeader("Content-Type", "application/json")
                .putHeader("Content-Length", String.valueOf(body.length()))
                .end(body);
    }

    static long parseId(String s) {
        int n = s.length();
        if (n == 0 || n > 18) return -1;
        long v = 0;
        for (int i = 0; i < n; i++) {
            char c = s.charAt(i);
            if (c < '0' || c > '9') return -1;
            v = v * 10 + (c - '0');
        }
        return v > 0 ? v : -1;
    }

    @Override
    public void start() {
        vertx.createHttpServer(new HttpServerOptions().setTcpNoDelay(true).setMaxInitialLineLength(8192))
                .requestHandler(this::handle)
                .listen(Integer.parseInt(System.getenv().getOrDefault("PORT", "8080")));
    }

    void handle(HttpServerRequest req) {
        String path = req.path();
        String method = req.method().name();
        if (path.equals("/health")) {
            send(req, 200, HEALTH);
            return;
        }
        if (method.equals("POST") && path.equals("/api/quote")) {
            req.body().onSuccess(b -> quote(req, b)).onFailure(e -> send(req, 400, BAD));
            return;
        }
        if (method.equals("POST") && path.equals("/api/orders")) {
            req.body().onSuccess(b -> createOrder(req, b)).onFailure(e -> send(req, 400, BAD));
            return;
        }
        if (!method.equals("GET") || !path.startsWith("/api/users/")) {
            send(req, 404, NOT_FOUND);
            return;
        }
        String rest = path.substring(11);
        int slash = rest.indexOf('/');
        long id = parseId(slash < 0 ? rest : rest.substring(0, slash));
        String tail = slash < 0 ? "" : rest.substring(slash);
        if (!tail.isEmpty() && !tail.equals("/orders") && !tail.equals("/summary")) {
            send(req, 404, NOT_FOUND);
            return;
        }
        if (id < 0) {
            send(req, 400, BAD);
            return;
        }
        switch (tail) {
            case "" -> pool.preparedQuery(SQL_USER).execute(Tuple.of(id)).onComplete(ar -> {
                if (ar.failed()) { fail(req, ar.cause()); return; }
                var it = ar.result().iterator();
                if (!it.hasNext()) { send(req, 404, NOT_FOUND); return; }
                Row r = it.next();
                send(req, 200, new JsonObject().put("id", r.getLong(0)).put("email", r.getString(1))
                        .put("name", r.getString(2)).put("country", r.getString(3))
                        .put("created_at", r.getString(4)).toBuffer());
            });
            case "/orders" -> {
                long limit = 20;
                String q = req.query();
                if (q != null) {
                    for (String part : q.split("&")) {
                        if (part.startsWith("limit=")) {
                            limit = parseId(part.substring(6));
                            if (limit > 100) limit = -1;
                        }
                    }
                }
                if (limit < 0) { send(req, 400, BAD); return; }
                pool.preparedQuery(SQL_ORDERS).execute(Tuple.of(id, limit)).onComplete(ar -> {
                    if (ar.failed()) { fail(req, ar.cause()); return; }
                    JsonArray orders = new JsonArray();
                    for (Row r : ar.result()) {
                        orders.add(new JsonObject().put("id", r.getLong(0)).put("sku", r.getString(1))
                                .put("qty", r.getInteger(2)).put("price_cents", r.getLong(3))
                                .put("status", r.getString(4)).put("created_at", r.getString(5)));
                    }
                    send(req, 200, new JsonObject().put("user_id", id).put("orders", orders).toBuffer());
                });
            }
            default -> pool.preparedQuery(SQL_SUMMARY).execute(Tuple.of(id)).onComplete(ar -> {
                if (ar.failed()) { fail(req, ar.cause()); return; }
                long count = 0, total = 0;
                JsonObject by = new JsonObject().put("cancelled", 0).put("delivered", 0).put("paid", 0)
                        .put("pending", 0).put("shipped", 0);
                for (Row r : ar.result()) {
                    long n = r.getLong(1);
                    by.put(r.getString(0), n);
                    count += n;
                    total += r.getNumeric(2).longValue();
                }
                send(req, 200, new JsonObject().put("user_id", id).put("order_count", count)
                        .put("total_cents", total).put("by_status", by).toBuffer());
            });
        }
    }

    static boolean isInt(Object o) {
        return o instanceof Integer || o instanceof Long;
    }

    void createOrder(HttpServerRequest req, Buffer body) {
        JsonObject o;
        try {
            o = body.toJsonObject();
        } catch (RuntimeException e) {
            send(req, 400, BAD);
            return;
        }
        Object uid = o.getValue("user_id"), sku = o.getValue("sku"), qty = o.getValue("qty"), price = o.getValue("price_cents");
        if (!isInt(uid) || !(sku instanceof String s) || !isInt(qty) || !isInt(price)) {
            send(req, 400, BAD);
            return;
        }
        long u = ((Number) uid).longValue(), q = ((Number) qty).longValue(), p = ((Number) price).longValue();
        int skuLen = s.codePointCount(0, s.length());
        if (u < 1 || q < 1 || q > 1000 || p < 1 || p > 1_000_000_000L || skuLen < 1 || skuLen > 32) {
            send(req, 400, BAD);
            return;
        }
        pool.preparedQuery(SQL_INSERT).execute(Tuple.of(u, s, (int) q, p)).onComplete(ar -> {
            if (ar.failed()) { fail(req, ar.cause()); return; }
            long id = ar.result().iterator().next().getLong(0);
            send(req, 201, new JsonObject().put("id", id).put("status", "pending").toBuffer());
        });
    }

    static boolean ahead(long an, String as, int ap, long bn, String bs, int bp) {
        if (an != bn) return an > bn;
        int c = as.compareTo(bs);
        if (c != 0) return c < 0;
        return ap < bp;
    }

    void quote(HttpServerRequest req, Buffer body) {
        JsonObject q;
        try {
            q = body.toJsonObject();
        } catch (RuntimeException e) {
            send(req, 400, BAD);
            return;
        }
        Long rate = q.getValue("region") instanceof String region ? RATES.get(region) : null;
        Object itemsV = q.getValue("items");
        if (rate == null || !(itemsV instanceof JsonArray items) || items.isEmpty()) {
            send(req, 400, BAD);
            return;
        }
        long sub = 0, disc = 0, tax = 0;
        long[] topNet = new long[5];
        String[] topSku = new String[5];
        int[] topPos = new int[5];
        int n = 0;
        int size = items.size();
        for (int pos = 0; pos < size; pos++) {
            JsonObject it = items.getJsonObject(pos);
            Object qv = it.getValue("qty"), pv = it.getValue("price_cents");
            if (!isInt(qv) || !isInt(pv)) { send(req, 400, BAD); return; }
            long qty = ((Number) qv).longValue(), price = ((Number) pv).longValue();
            if (qty < 1 || price < 0) { send(req, 400, BAD); return; }
            String sku = it.getString("sku");
            long gross = qty * price;
            long d = qty >= 10 ? gross * 500 / 10000 : 0;
            long net = gross - d;
            sub += gross;
            disc += d;
            tax += net * rate / 10000;
            if (n < 5 || ahead(net, sku, pos, topNet[n - 1], topSku[n - 1], topPos[n - 1])) {
                int at = n < 5 ? n++ : 4;
                while (at > 0 && ahead(net, sku, pos, topNet[at - 1], topSku[at - 1], topPos[at - 1])) {
                    topNet[at] = topNet[at - 1];
                    topSku[at] = topSku[at - 1];
                    topPos[at] = topPos[at - 1];
                    at--;
                }
                topNet[at] = net;
                topSku[at] = sku;
                topPos[at] = pos;
            }
        }
        JsonArray skus = new JsonArray();
        for (int i = 0; i < n; i++) skus.add(topSku[i]);
        send(req, 200, new JsonObject().put("region", q.getString("region")).put("lines", size)
                .put("subtotal_cents", sub).put("discount_cents", disc).put("tax_cents", tax)
                .put("total_cents", sub - disc + tax).put("top_skus", skus).toBuffer());
    }

    public static void main(String[] args) {
        int workers = Integer.parseInt(System.getenv().getOrDefault("WORKERS",
                String.valueOf(Runtime.getRuntime().availableProcessors())));
        int poolSize = Integer.parseInt(System.getenv().getOrDefault("DB_POOL_TOTAL", "64"));
        Vertx vertx = Vertx.vertx(new VertxOptions().setEventLoopPoolSize(workers).setPreferNativeTransport(true));
        PgConnectOptions connect = PgConnectOptions.fromUri(System.getenv("DATABASE_URL"))
                .setCachePreparedStatements(true).setPipeliningLimit(256);
        pool = PgBuilder.pool().with(new PoolOptions().setMaxSize(poolSize))
                .connectingTo(connect).using(vertx).build();
        vertx.deployVerticle(Main.class.getName(), new DeploymentOptions().setInstances(workers))
                .onSuccess(id -> System.out.println("listening on " + System.getenv().getOrDefault("PORT", "8080")))
                .onFailure(e -> { e.printStackTrace(); System.exit(1); });
    }
}

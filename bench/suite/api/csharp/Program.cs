// heavy/api in C#: ASP.NET Core Kestrel minimal API, Npgsql data source,
// source-generated System.Text.Json, Server GC. See bench/SPEC.md.
using System.Text.Json;
using System.Text.Json.Serialization;
using Npgsql;

const string TS = "to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')";
string sqlUser = $"SELECT id, email, name, country, {TS} FROM users WHERE id = $1";
string sqlOrders = $"SELECT id, sku, qty, price_cents, status, {TS} FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2";
const string sqlSummary = "SELECT status, count(*), coalesce(sum(qty * price_cents), 0) FROM orders WHERE user_id = $1 GROUP BY status";
const string sqlInsert = "INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id";

var rates = new Dictionary<string, long> {
    ["US"] = 725, ["CA"] = 1300, ["UK"] = 2000, ["EU"] = 2000, ["DE"] = 1900, ["FR"] = 2000,
    ["JP"] = 1000, ["IN"] = 1800, ["BR"] = 1700, ["NG"] = 750, ["AU"] = 1000,
};

int poolSize = int.TryParse(Environment.GetEnvironmentVariable("DB_POOL_TOTAL"), out var p) && p > 0 ? p : 64;
var connString = ToNpgsql(Environment.GetEnvironmentVariable("DATABASE_URL") ?? "", poolSize);
await using var db = NpgsqlDataSource.Create(connString);

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.WebHost.ConfigureKestrel(o => {
    o.AddServerHeader = false;
    o.Limits.MaxRequestBodySize = 8 * 1024 * 1024;
    o.ListenAnyIP(int.TryParse(Environment.GetEnvironmentVariable("PORT"), out var port) ? port : 8080);
});
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.TypeInfoResolverChain.Insert(0, Ctx.Default));
var app = builder.Build();

IResult Json<T>(int status, T value, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> info) =>
    new JsonBytesResult(status, JsonSerializer.SerializeToUtf8Bytes(value, info));
IResult Raw(int status, string body) => Results.Text(body, "application/json", statusCode: status);
IResult Bad() => Raw(400, "{\"error\":\"bad request\"}");
IResult NotFound() => Raw(404, "{\"error\":\"not found\"}");

app.MapGet("/health", () => Raw(200, "{\"ok\":true}"));

app.MapGet("/api/users/{id}", async (string id) => {
    long uid = ParseId(id);
    if (uid < 0) return Bad();
    await using var cmd = db.CreateCommand(sqlUser);
    cmd.Parameters.Add(new NpgsqlParameter<long> { TypedValue = uid });
    await using var r = await cmd.ExecuteReaderAsync();
    if (!await r.ReadAsync()) return NotFound();
    return Json(200, new User(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4)), Ctx.Default.User);
});

app.MapGet("/api/users/{id}/orders", async (string id, HttpRequest req) => {
    long uid = ParseId(id);
    long limit = 20;
    if (req.Query.TryGetValue("limit", out var lv)) {
        limit = ParseId(lv.ToString());
        if (limit > 100) limit = -1;
    }
    if (uid < 0 || limit < 0) return Bad();
    await using var cmd = db.CreateCommand(sqlOrders);
    cmd.Parameters.Add(new NpgsqlParameter<long> { TypedValue = uid });
    cmd.Parameters.Add(new NpgsqlParameter<long> { TypedValue = limit });
    await using var r = await cmd.ExecuteReaderAsync();
    var orders = new List<Order>((int)limit);
    while (await r.ReadAsync())
        orders.Add(new Order(r.GetInt64(0), r.GetString(1), r.GetInt32(2), r.GetInt64(3), r.GetString(4), r.GetString(5)));
    return Json(200, new OrderList(uid, orders), Ctx.Default.OrderList);
});

app.MapGet("/api/users/{id}/summary", async (string id) => {
    long uid = ParseId(id);
    if (uid < 0) return Bad();
    await using var cmd = db.CreateCommand(sqlSummary);
    cmd.Parameters.Add(new NpgsqlParameter<long> { TypedValue = uid });
    await using var r = await cmd.ExecuteReaderAsync();
    var by = new ByStatus();
    long count = 0, total = 0;
    while (await r.ReadAsync()) {
        long n = r.GetInt64(1);
        switch (r.GetString(0)) {
            case "cancelled": by.cancelled = n; break;
            case "delivered": by.delivered = n; break;
            case "paid": by.paid = n; break;
            case "pending": by.pending = n; break;
            case "shipped": by.shipped = n; break;
        }
        count += n;
        total += (long)r.GetDecimal(2);
    }
    return Json(200, new Summary(uid, count, total, by), Ctx.Default.Summary);
});

app.MapPost("/api/orders", async (HttpRequest req) => {
    NewOrder? o;
    try { o = await JsonSerializer.DeserializeAsync(req.Body, Ctx.Default.NewOrder); }
    catch (JsonException) { return Bad(); }
    if (o is null || o.user_id is not long uid || o.sku is not string sku || o.qty is not long qty ||
        o.price_cents is not long price || uid < 1 || qty < 1 || qty > 1000 || price < 1 || price > 1_000_000_000) return Bad();
    int skuLen = sku.EnumerateRunes().Count();
    if (skuLen < 1 || skuLen > 32) return Bad();
    await using var cmd = db.CreateCommand(sqlInsert);
    cmd.Parameters.Add(new NpgsqlParameter<long> { TypedValue = uid });
    cmd.Parameters.Add(new NpgsqlParameter<string> { TypedValue = sku });
    cmd.Parameters.Add(new NpgsqlParameter<int> { TypedValue = (int)qty });
    cmd.Parameters.Add(new NpgsqlParameter<long> { TypedValue = price });
    var newId = (long)(await cmd.ExecuteScalarAsync())!;
    return Json(201, new Created(newId, "pending"), Ctx.Default.Created);
});

app.MapPost("/api/quote", async (HttpRequest req) => {
    QuoteReq? q;
    try { q = await JsonSerializer.DeserializeAsync(req.Body, Ctx.Default.QuoteReq); }
    catch (JsonException) { return Bad(); }
    if (q?.region is null || q.items is null || q.items.Count == 0 || !rates.TryGetValue(q.region, out var rate)) return Bad();
    long sub = 0, disc = 0, tax = 0;
    Span<long> topNet = stackalloc long[5];
    var topSku = new string[5];
    Span<int> topPos = stackalloc int[5];
    int n = 0;
    for (int pos = 0; pos < q.items.Count; pos++) {
        var it = q.items[pos];
        if (it.qty < 1 || it.price_cents < 0) return Bad();
        long gross = it.qty * it.price_cents;
        long d = it.qty >= 10 ? gross * 500 / 10000 : 0;
        long net = gross - d;
        sub += gross;
        disc += d;
        tax += net * rate / 10000;
        if (n < 5 || Ahead(net, it.sku, pos, topNet[n - 1], topSku[n - 1], topPos[n - 1])) {
            int at = n < 5 ? n++ : 4;
            while (at > 0 && Ahead(net, it.sku, pos, topNet[at - 1], topSku[at - 1], topPos[at - 1])) {
                topNet[at] = topNet[at - 1];
                topSku[at] = topSku[at - 1];
                topPos[at] = topPos[at - 1];
                at--;
            }
            topNet[at] = net;
            topSku[at] = it.sku;
            topPos[at] = pos;
        }
    }
    return Json(200, new QuoteResp(q.region, q.items.Count, sub, disc, tax, sub - disc + tax, topSku[..n]), Ctx.Default.QuoteResp);
});

app.MapFallback(() => NotFound());
Console.WriteLine("listening");
app.Run();

static bool Ahead(long an, string asku, int ap, long bn, string bsku, int bp) {
    if (an != bn) return an > bn;
    int c = string.CompareOrdinal(asku, bsku);
    if (c != 0) return c < 0;
    return ap < bp;
}

static long ParseId(string s) {
    if (s.Length == 0 || s.Length > 18) return -1;
    long v = 0;
    foreach (char c in s) {
        if (c < '0' || c > '9') return -1;
        v = v * 10 + (c - '0');
    }
    return v > 0 ? v : -1;
}

// postgres://user:pass@host:port/db -> an Npgsql connection string
static string ToNpgsql(string url, int pool) {
    var u = new Uri(url);
    var userInfo = u.UserInfo.Split(':', 2);
    return $"Host={u.Host};Port={(u.Port > 0 ? u.Port : 5432)};Username={Uri.UnescapeDataString(userInfo[0])};" +
           $"Password={(userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : "")};Database={u.AbsolutePath.TrimStart('/')};" +
           $"Minimum Pool Size={pool};Maximum Pool Size={pool};No Reset On Close=true;Max Auto Prepare=20;Auto Prepare Min Usages=1;SSL Mode=Disable";
}

// Results.Bytes has no statusCode overload in net10.0's minimal-API shape,
// so write the pre-serialized UTF-8 body straight to the response ourselves
// (also skips the intermediate copy Results.Text would do for a string).
sealed class JsonBytesResult : IResult {
    readonly int status;
    readonly byte[] body;
    public JsonBytesResult(int status, byte[] body) { this.status = status; this.body = body; }
    public Task ExecuteAsync(HttpContext ctx) {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentLength = body.Length;
        return ctx.Response.Body.WriteAsync(body).AsTask();
    }
}

record User(long id, string email, string name, string country, string created_at);
record Order(long id, string sku, int qty, long price_cents, string status, string created_at);
record OrderList(long user_id, List<Order> orders);
class ByStatus { public long cancelled { get; set; } public long delivered { get; set; } public long paid { get; set; } public long pending { get; set; } public long shipped { get; set; } }
record Summary(long user_id, long order_count, long total_cents, ByStatus by_status);
record NewOrder(long? user_id, string? sku, long? qty, long? price_cents);
record Created(long id, string status);
record QuoteItem(string sku, long qty, long price_cents);
record QuoteReq(string? region, List<QuoteItem>? items);
record QuoteResp(string region, int lines, long subtotal_cents, long discount_cents, long tax_cents, long total_cents, string[] top_skus);

[JsonSerializable(typeof(User))]
[JsonSerializable(typeof(OrderList))]
[JsonSerializable(typeof(Summary))]
[JsonSerializable(typeof(NewOrder))]
[JsonSerializable(typeof(Created))]
[JsonSerializable(typeof(QuoteReq))]
[JsonSerializable(typeof(QuoteResp))]
partial class Ctx : JsonSerializerContext { }

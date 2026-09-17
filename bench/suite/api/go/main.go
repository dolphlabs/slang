// heavy/api in Go: fasthttp + pgx/v5 pool + goccy/go-json. See bench/SPEC.md.
package main

import (
	"bytes"
	"context"
	"log"
	"os"
	"runtime"
	"strconv"
	"unicode/utf8"

	json "github.com/goccy/go-json"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/valyala/fasthttp"
)

const ts = `to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')`

const (
	sqlUser    = `SELECT id, email, name, country, ` + ts + ` FROM users WHERE id = $1`
	sqlOrders  = `SELECT id, sku, qty, price_cents, status, ` + ts + ` FROM orders WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2`
	sqlSummary = `SELECT status, count(*), coalesce(sum(qty * price_cents), 0) FROM orders WHERE user_id = $1 GROUP BY status`
	sqlInsert  = `INSERT INTO orders (user_id, sku, qty, price_cents, status, created_at) VALUES ($1, $2, $3, $4, 'pending', now()) RETURNING id`
)

var (
	pool        *pgxpool.Pool
	notFound    = []byte(`{"error":"not found"}`)
	badRequest  = []byte(`{"error":"bad request"}`)
	healthBody  = []byte(`{"ok":true}`)
	jsonType    = []byte("application/json")
	prefixUsers = []byte("/api/users/")
)

var rates = map[string]int64{"US": 725, "CA": 1300, "UK": 2000, "EU": 2000, "DE": 1900,
	"FR": 2000, "JP": 1000, "IN": 1800, "BR": 1700, "NG": 750, "AU": 1000}

type user struct {
	ID        int64  `json:"id"`
	Email     string `json:"email"`
	Name      string `json:"name"`
	Country   string `json:"country"`
	CreatedAt string `json:"created_at"`
}

type order struct {
	ID         int64  `json:"id"`
	SKU        string `json:"sku"`
	Qty        int32  `json:"qty"`
	PriceCents int64  `json:"price_cents"`
	Status     string `json:"status"`
	CreatedAt  string `json:"created_at"`
}

type orderList struct {
	UserID int64   `json:"user_id"`
	Orders []order `json:"orders"`
}

type byStatus struct {
	Cancelled int64 `json:"cancelled"`
	Delivered int64 `json:"delivered"`
	Paid      int64 `json:"paid"`
	Pending   int64 `json:"pending"`
	Shipped   int64 `json:"shipped"`
}

type summary struct {
	UserID     int64    `json:"user_id"`
	OrderCount int64    `json:"order_count"`
	TotalCents int64    `json:"total_cents"`
	ByStatus   byStatus `json:"by_status"`
}

type newOrder struct {
	UserID     *int64  `json:"user_id"`
	SKU        *string `json:"sku"`
	Qty        *int64  `json:"qty"`
	PriceCents *int64  `json:"price_cents"`
}

type created struct {
	ID     int64  `json:"id"`
	Status string `json:"status"`
}

type quoteItem struct {
	SKU        string `json:"sku"`
	Qty        int64  `json:"qty"`
	PriceCents int64  `json:"price_cents"`
}

type quoteReq struct {
	Region string      `json:"region"`
	Items  []quoteItem `json:"items"`
}

type quoteResp struct {
	Region        string   `json:"region"`
	Lines         int      `json:"lines"`
	SubtotalCents int64    `json:"subtotal_cents"`
	DiscountCents int64    `json:"discount_cents"`
	TaxCents      int64    `json:"tax_cents"`
	TotalCents    int64    `json:"total_cents"`
	TopSKUs       []string `json:"top_skus"`
}

func reply(ctx *fasthttp.RequestCtx, status int, body []byte) {
	ctx.SetStatusCode(status)
	ctx.Response.Header.SetContentTypeBytes(jsonType)
	ctx.SetBody(body)
}

func replyJSON(ctx *fasthttp.RequestCtx, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		reply(ctx, 500, []byte(`{"error":"internal"}`))
		return
	}
	reply(ctx, status, b)
}

// A positive int64 of digits only.
func parseID(b []byte) (int64, bool) {
	if len(b) == 0 || len(b) > 18 {
		return 0, false
	}
	var n int64
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
	}
	return n, n > 0
}

func handler(ctx *fasthttp.RequestCtx) {
	path := ctx.Path()
	method := ctx.Method()
	switch {
	case bytes.Equal(path, []byte("/health")):
		reply(ctx, 200, healthBody)
	case bytes.HasPrefix(path, prefixUsers) && string(method) == "GET":
		rest := path[len(prefixUsers):]
		slash := bytes.IndexByte(rest, '/')
		idPart, tail := rest, []byte(nil)
		if slash >= 0 {
			idPart, tail = rest[:slash], rest[slash:]
		}
		id, ok := parseID(idPart)
		switch string(tail) {
		case "":
			if !ok {
				reply(ctx, 400, badRequest)
				return
			}
			getUser(ctx, id)
		case "/orders":
			limit := int64(20)
			args := ctx.QueryArgs()
			if args.Has("limit") {
				l, lok := parseID(args.Peek("limit"))
				if !lok || l > 100 {
					ok = false
				}
				limit = l
			}
			if !ok {
				reply(ctx, 400, badRequest)
				return
			}
			getOrders(ctx, id, limit)
		case "/summary":
			if !ok {
				reply(ctx, 400, badRequest)
				return
			}
			getSummary(ctx, id)
		default:
			reply(ctx, 404, notFound)
		}
	case bytes.Equal(path, []byte("/api/orders")) && string(method) == "POST":
		createOrder(ctx)
	case bytes.Equal(path, []byte("/api/quote")) && string(method) == "POST":
		quote(ctx)
	default:
		reply(ctx, 404, notFound)
	}
}

func getUser(ctx *fasthttp.RequestCtx, id int64) {
	var u user
	err := pool.QueryRow(context.Background(), sqlUser, id).
		Scan(&u.ID, &u.Email, &u.Name, &u.Country, &u.CreatedAt)
	if err != nil {
		if err.Error() == "no rows in result set" {
			reply(ctx, 404, notFound)
			return
		}
		reply(ctx, 500, []byte(`{"error":"internal"}`))
		return
	}
	replyJSON(ctx, 200, &u)
}

func getOrders(ctx *fasthttp.RequestCtx, id, limit int64) {
	rows, err := pool.Query(context.Background(), sqlOrders, id, limit)
	if err != nil {
		reply(ctx, 500, []byte(`{"error":"internal"}`))
		return
	}
	defer rows.Close()
	out := orderList{UserID: id, Orders: make([]order, 0, limit)}
	for rows.Next() {
		var o order
		if err := rows.Scan(&o.ID, &o.SKU, &o.Qty, &o.PriceCents, &o.Status, &o.CreatedAt); err != nil {
			reply(ctx, 500, []byte(`{"error":"internal"}`))
			return
		}
		out.Orders = append(out.Orders, o)
	}
	if rows.Err() != nil {
		reply(ctx, 500, []byte(`{"error":"internal"}`))
		return
	}
	replyJSON(ctx, 200, &out)
}

func getSummary(ctx *fasthttp.RequestCtx, id int64) {
	rows, err := pool.Query(context.Background(), sqlSummary, id)
	if err != nil {
		reply(ctx, 500, []byte(`{"error":"internal"}`))
		return
	}
	defer rows.Close()
	s := summary{UserID: id}
	for rows.Next() {
		var status string
		var n, total int64
		if err := rows.Scan(&status, &n, &total); err != nil {
			reply(ctx, 500, []byte(`{"error":"internal"}`))
			return
		}
		switch status {
		case "cancelled":
			s.ByStatus.Cancelled = n
		case "delivered":
			s.ByStatus.Delivered = n
		case "paid":
			s.ByStatus.Paid = n
		case "pending":
			s.ByStatus.Pending = n
		case "shipped":
			s.ByStatus.Shipped = n
		}
		s.OrderCount += n
		s.TotalCents += total
	}
	replyJSON(ctx, 200, &s)
}

func createOrder(ctx *fasthttp.RequestCtx) {
	var in newOrder
	if json.Unmarshal(ctx.PostBody(), &in) != nil ||
		in.UserID == nil || in.SKU == nil || in.Qty == nil || in.PriceCents == nil ||
		*in.UserID < 1 || *in.Qty < 1 || *in.Qty > 1000 ||
		*in.PriceCents < 1 || *in.PriceCents > 1000000000 {
		reply(ctx, 400, badRequest)
		return
	}
	if n := utf8.RuneCountInString(*in.SKU); n < 1 || n > 32 {
		reply(ctx, 400, badRequest)
		return
	}
	var id int64
	err := pool.QueryRow(context.Background(), sqlInsert,
		*in.UserID, *in.SKU, int32(*in.Qty), *in.PriceCents).Scan(&id)
	if err != nil {
		reply(ctx, 500, []byte(`{"error":"internal"}`))
		return
	}
	replyJSON(ctx, 201, &created{ID: id, Status: "pending"})
}

type ranked struct {
	net int64
	sku string
	pos int
}

// before reports whether a ranks ahead of b: larger net, then sku, then position.
func before(a, b ranked) bool {
	if a.net != b.net {
		return a.net > b.net
	}
	if a.sku != b.sku {
		return a.sku < b.sku
	}
	return a.pos < b.pos
}

func quote(ctx *fasthttp.RequestCtx) {
	var in quoteReq
	if json.Unmarshal(ctx.PostBody(), &in) != nil || len(in.Items) == 0 {
		reply(ctx, 400, badRequest)
		return
	}
	rate, ok := rates[in.Region]
	if !ok {
		reply(ctx, 400, badRequest)
		return
	}
	var sub, disc, tax int64
	var top [5]ranked
	n := 0
	for pos, it := range in.Items {
		if it.Qty < 1 || it.PriceCents < 0 {
			reply(ctx, 400, badRequest)
			return
		}
		gross := it.Qty * it.PriceCents
		var d int64
		if it.Qty >= 10 {
			d = gross * 500 / 10000
		}
		net := gross - d
		sub += gross
		disc += d
		tax += net * rate / 10000
		r := ranked{net, it.SKU, pos}
		if n < 5 {
			top[n] = r
			n++
		} else if before(r, top[4]) {
			top[4] = r
		} else {
			continue
		}
		for i := n - 1; i > 0 && before(top[i], top[i-1]); i-- {
			top[i], top[i-1] = top[i-1], top[i]
		}
	}
	skus := make([]string, n)
	for i := 0; i < n; i++ {
		skus[i] = top[i].sku
	}
	replyJSON(ctx, 200, &quoteResp{in.Region, len(in.Items), sub, disc, tax, sub - disc + tax, skus})
}

func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return def
}

func main() {
	workers := envInt("WORKERS", runtime.NumCPU())
	runtime.GOMAXPROCS(workers)
	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	cfg.MaxConns = int32(envInt("DB_POOL_TOTAL", 64))
	cfg.MinConns = cfg.MaxConns
	pool, err = pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Fatal(err)
	}
	srv := &fasthttp.Server{
		Handler:                       handler,
		Name:                          "go",
		MaxRequestBodySize:            8 << 20,
		DisableHeaderNamesNormalizing: true,
		NoDefaultDate:                 true,
		NoDefaultServerHeader:         true,
	}
	addr := ":" + strconv.Itoa(envInt("PORT", 8080))
	log.Printf("listening on %s", addr)
	log.Fatal(srv.ListenAndServe(addr))
}

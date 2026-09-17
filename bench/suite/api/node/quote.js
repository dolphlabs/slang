// POST /api/quote, shared by the Node and Bun servers (bench/SPEC.md).
const RATES = { US: 725, CA: 1300, UK: 2000, EU: 2000, DE: 1900, FR: 2000,
                JP: 1000, IN: 1800, BR: 1700, NG: 750, AU: 1000 };

function ahead(an, as, ap, bn, bs, bp) {
  if (an !== bn) return an > bn;
  if (as !== bs) return as < bs;
  return ap < bp;
}

// Returns the response object, or null for a bad request. Values stay
// well inside 2^53: 2000 lines × 25 × 100,000 cents.
export function quote(body) {
  let q;
  try { q = JSON.parse(body); } catch { return null; }
  const rate = RATES[q && q.region];
  if (rate === undefined || !Array.isArray(q.items) || q.items.length === 0) return null;
  let sub = 0, disc = 0, tax = 0;
  const topNet = [], topSku = [], topPos = [];
  const items = q.items;
  for (let pos = 0; pos < items.length; pos++) {
    const it = items[pos];
    const qty = it.qty, price = it.price_cents;
    if (!Number.isInteger(qty) || !Number.isInteger(price) || qty < 1 || price < 0) return null;
    const gross = qty * price;
    const d = qty >= 10 ? Math.floor(gross * 500 / 10000) : 0;
    const net = gross - d;
    sub += gross;
    disc += d;
    tax += Math.floor(net * rate / 10000);
    let n = topNet.length;
    if (n < 5 || ahead(net, it.sku, pos, topNet[n - 1], topSku[n - 1], topPos[n - 1])) {
      if (n === 5) { topNet.pop(); topSku.pop(); topPos.pop(); n--; }
      let at = n;
      while (at > 0 && ahead(net, it.sku, pos, topNet[at - 1], topSku[at - 1], topPos[at - 1])) at--;
      topNet.splice(at, 0, net);
      topSku.splice(at, 0, it.sku);
      topPos.splice(at, 0, pos);
    }
  }
  return { region: q.region, lines: items.length, subtotal_cents: sub, discount_cents: disc,
           tax_cents: tax, total_cents: sub - disc + tax, top_skus: topSku };
}

export function parseId(s) {
  if (!s || s.length > 18 || !/^[0-9]+$/.test(s)) return -1;
  const n = Number(s);
  return n > 0 && Number.isSafeInteger(n) ? n : -1;
}

export const TS = `to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')`;

-- api scenario `mix` (bench/SPEC.md): 50% user by id, 15% orders limit 50,
-- 10% summary, 10% create order, 15% quote.
package.path = "bench/suite/lib/?.lua;" .. package.path
local common = require("common")

local counter = 0
function setup(thread)
  thread:set("tid", counter)
  counter = counter + 1
end

local bodies
function init(args)
  math.randomseed(3000 + tid)
  bodies = common.load_quotes()
end

function request()
  local roll = math.random(1, 100)
  local id = math.random(1, common.users)
  if roll <= 50 then
    return wrk.format("GET", "/api/users/" .. id)
  elseif roll <= 65 then
    return wrk.format("GET", "/api/users/" .. id .. "/orders?limit=50")
  elseif roll <= 75 then
    return wrk.format("GET", "/api/users/" .. id .. "/summary")
  elseif roll <= 85 then
    local body = string.format('{"user_id":%d,"sku":"SKU-%05d","qty":%d,"price_cents":%d}',
      id, math.random(0, 99999), math.random(1, 20), math.random(100, 99999))
    return wrk.format("POST", "/api/orders", common.json_headers, body)
  else
    return wrk.format("POST", "/api/quote", common.json_headers, bodies[math.random(1, #bodies)])
  end
end

-- per-status counts, so a server answering 400s/500s quickly cannot look fast
function done(summary, latency, requests)
  io.write(string.format("MIX_ERRORS connect=%d read=%d write=%d status=%d timeout=%d\n",
    summary.errors.connect, summary.errors.read, summary.errors.write,
    summary.errors.status, summary.errors.timeout))
end

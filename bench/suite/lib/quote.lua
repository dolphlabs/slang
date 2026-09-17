-- api scenario `quote`: POST /api/quote with pre-generated ~110KB bodies.
package.path = "bench/suite/lib/?.lua;" .. package.path
local common = require("common")

local counter = 0
function setup(thread)
  thread:set("tid", counter)
  counter = counter + 1
end

local bodies
function init(args)
  math.randomseed(2000 + tid)
  bodies = common.load_quotes()
end

function request()
  return wrk.format("POST", "/api/quote", common.json_headers, bodies[math.random(1, #bodies)])
end

function done(summary, latency, requests)
  io.write(string.format("MIX_ERRORS connect=%d read=%d write=%d status=%d timeout=%d\n",
    summary.errors.connect, summary.errors.read, summary.errors.write,
    summary.errors.status, summary.errors.timeout))
end

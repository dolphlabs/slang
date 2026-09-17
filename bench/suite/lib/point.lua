-- api scenario `point`: GET /api/users/{id}, uniform ids.
package.path = "bench/suite/lib/?.lua;" .. package.path
local common = require("common")

local counter = 0
function setup(thread)
  thread:set("tid", counter)
  counter = counter + 1
end

function init(args)
  math.randomseed(1000 + tid)
end

function request()
  return wrk.format("GET", "/api/users/" .. math.random(1, common.users))
end

function done(summary, latency, requests)
  io.write(string.format("MIX_ERRORS connect=%d read=%d write=%d status=%d timeout=%d\n",
    summary.errors.connect, summary.errors.read, summary.errors.write,
    summary.errors.status, summary.errors.timeout))
end

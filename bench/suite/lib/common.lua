-- Shared by the api load scripts (bench/SPEC.md). Deterministic: each wrk
-- thread seeds its generator from its own index, so a run's request
-- sequence depends only on USERS, the thread count and the seed.
local M = {}

M.users = tonumber(os.getenv("USERS") or "1000000")
M.quote_dir = os.getenv("QUOTE_DIR") or "bench/suite/data/quotes"

function M.load_quotes()
  local bodies = {}
  for i = 0, 63 do
    local f = io.open(M.quote_dir .. "/quote_" .. i .. ".json", "rb")
    if not f then break end
    bodies[#bodies + 1] = f:read("*a")
    f:close()
  end
  assert(#bodies > 0, "no quote bodies in " .. M.quote_dir)
  return bodies
end

M.json_headers = { ["Content-Type"] = "application/json" }

return M
